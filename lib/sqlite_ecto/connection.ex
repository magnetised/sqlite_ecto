if Code.ensure_loaded?(Sqlitex.Server) do
  defmodule Sqlite.Ecto.Connection do
    @moduledoc false

    @behaviour Ecto.Adapters.SQL.Connection

    def connect(opts) do
      opts |> Sqlite.Ecto.get_name |> Sqlitex.Server.start_link
    end

    def disconnect(pid) do
      Sqlitex.Server.stop(pid)
      :ok
    end

    def query(pid, sql, params \\ []) do
      params = Enum.map(params, fn
        %Ecto.Query.Tagged{value: value} -> value
        value -> value
      end)

      if has_returning_clause?(sql) do
        returning_query(pid, sql, params)
      else
        do_query(pid, sql, params)
      end
    end

    ## Transaction

    def begin_transaction, do: "BEGIN"

    def rollback, do: "ROLLBACK"

    def commit, do: "COMMIT"

    def savepoint(name), do: "SAVEPOINT " <> name

    def rollback_to_savepoint(name), do: "ROLLBACK TO " <> name

    ## Query

    def all(query) do
    end

    def update_all(query, values) do
    end

    def delete_all(query) do
    end

    def insert(table, [], returning) do
      rets = returning_clause(table, returning)
      "INSERT INTO #{table} DEFAULT VALUES" <> rets
    end
    def insert(table, fields, returning) do
      cols = Enum.join(fields, ",")
      vals = 1..length(fields) |> Enum.map_join(",", &"?#{&1}")
      rets = returning_clause(table, returning)
      "INSERT INTO #{table} (#{cols}) VALUES (#{vals})" <> rets
    end

    def update(table, fields, filters, returning) do
      {vals, count} = Enum.map_reduce(fields, 1, fn (i, acc) ->
        {"#{i} = ?#{acc}", acc + 1}
      end)
      where = where_filter(filters, count)
      rets = returning_clause(table, returning)
      "UPDATE #{table} SET " <> Enum.join(vals, ", ") <> where <> rets
    end

    def delete(table, filters, returning) do
      where = where_filter(filters)
      return = returning_clause(table, returning)
      "DELETE FROM " <> table <> where <> return
    end

    ## DDL

    ## Helpers

    defp has_returning_clause?(sql) do
      String.contains?(sql, " RETURNING ") and
      (String.starts_with?(sql, "INSERT ") or
       String.starts_with?(sql, "UPDATE ") or
       String.starts_with?(sql, "DELETE "))
    end

    # SQLite does not have any sort of "RETURNING" clause... so we have to
    # fake one with the following transaction:
    #
    #   BEGIN TRANSACTION;
    #   CREATE TEMP TABLE temp.t_<random> (<returning>);
    #   CREATE TEMP TRIGGER tr_<random> AFTER UPDATE ON main.<table> BEGIN
    #       INSERT INTO t_<random> SELECT NEW.<returning>;
    #   END;
    #   UPDATE ...;
    #   DROP TRIGGER tr_<random>;
    #   SELECT <returning> FROM temp.t_<random>;
    #   DROP TABLE temp.t_<random>;
    #   END TRANSACTION;
    #
    # which is implemented by the following code:
    defp returning_query(pid, sql, params) do
      {sql, table, returning} = parse_returning_clause(sql)
      {query, ref} = parse_query_type(sql)

      with_transaction(pid, fn ->
        with_temp_table(pid, returning, fn (tmp_tbl) ->
          err = with_temp_trigger(pid, table, tmp_tbl, returning, query, ref, fn ->
            do_query(pid, sql, params)
          end)

          case err do
            {:error, _} -> err
            _ ->
              do_query(pid, "SELECT #{Enum.join(returning, ", ")} FROM #{tmp_tbl}")
          end
        end)
      end)
    end

    defp parse_returning_clause(sql) do
      [sql, returning_clause] = String.split(sql, " RETURNING ")
      returning_clause
      |> String.split("|")
      |> (fn [table, rest] -> {sql, table, String.split(rest, ",")} end).()
    end

    defp parse_query_type(sql) do
      case sql do
        << "INSERT", _ :: binary >> -> {"INSERT", "NEW"}
        << "UPDATE", _ :: binary >> -> {"UPDATE", "NEW"}
        << "DELETE", _ :: binary >> -> {"DELETE", "OLD"}
      end
    end

    defp with_transaction(pid, func) do
      should_commit? = (do_exec(pid, "BEGIN TRANSACTION") == :ok)
      result = func.()
      error? = (is_tuple(result) and :erlang.element(1, result) == :error)

      do_exec(pid, cond do
        error? -> "ROLLBACK"
        should_commit? -> "END TRANSACTION"
        true -> "" # do nothing
      end)
      result
    end

    defp with_temp_table(pid, returning, func) do
      tmp = "t_" <> (:random.uniform |> Float.to_string |> String.slice(2..10))
      fields = Enum.join(returning, ", ")
      results = case do_exec(pid, "CREATE TEMP TABLE #{tmp} (#{fields})") do
        {:error, _} = err -> err
        _ -> func.(tmp)
      end
      do_exec(pid, "DROP TABLE IF EXISTS #{tmp}")
      results
    end

    defp with_temp_trigger(pid, table, tmp_tbl, returning, query, ref, func) do
      tmp = "tr_" <> (:random.uniform |> Float.to_string |> String.slice(2..10))
      fields = Enum.map_join(returning, ", ", &"#{ref}.#{&1}")
      sql = """
      CREATE TEMP TRIGGER #{tmp} AFTER #{query} ON main.#{table} BEGIN
          INSERT INTO #{tmp_tbl} SELECT #{fields};
      END;
      """
      results = case do_exec(pid, sql) do
        {:error, _} = err -> err
        _ -> func.()
      end
      do_exec(pid, "DROP TRIGGER IF EXISTS #{tmp}")
      results
    end

    defp do_query(pid, sql, params \\ []) do
      case Sqlitex.Server.query(pid, sql, params) do
        # busy error means another process is writing to the database; try again
        {:error, {:busy, _}} -> do_query(pid, sql, params)
        {:error, _} = error -> error
        rows when is_list(rows) ->
          {:ok, %{rows: rows, num_rows: length(rows)}}
      end
    end

    defp do_exec(pid, sql) do
      case Sqlitex.Server.exec(pid, sql) do
        # busy error means another process is writing to the database; try again
        {:error, {:busy, _}} -> do_exec(pid, sql)
        {:error, _} = error -> error
        :ok -> :ok
      end
    end

    defp returning_clause(_table, []), do: ""
    defp returning_clause(table, returning) do
      " RETURNING #{table}|#{Enum.join(returning, ",")}"
    end

    defp where_filter(filters), do: where_filter(filters, 1)
    defp where_filter([], _start), do: ""
    defp where_filter(filters, start) do
      filters
      |> Enum.map_reduce(start, fn (i, acc) -> {"#{i} = ?#{acc}", acc + 1} end)
      |> (fn ({filters, _acc}) -> filters end).()
      |> Enum.join(" AND ")
      |> (fn (clause) -> " WHERE " <> clause end).()
    end
  end
end
