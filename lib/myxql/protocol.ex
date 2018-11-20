defmodule MyXQL.Protocol do
  @moduledoc false
  use DBConnection
  import MyXQL.Messages
  alias MyXQL.{Cursor, Error, Query, Result}

  defstruct [
    :sock,
    :connection_id,
    transaction_status: :idle,
    # TODO: GC prepared statements?
    prepared_statements: %{},
    cursor: nil
  ]

  @impl true
  def connect(opts) do
    default_port = String.to_integer(System.get_env("MYSQL_TCP_PORT") || "3306")

    hostname = Keyword.fetch!(opts, :hostname)
    port = Keyword.get(opts, :port, default_port)
    username = Keyword.fetch!(opts, :username)
    password = Keyword.get(opts, :password)
    database = Keyword.get(opts, :database)
    timeout = Keyword.get(opts, :timeout, 5000)
    ssl? = Keyword.get(opts, :ssl, false)
    ssl_opts = Keyword.get(opts, :ssl_opts, [])

    # TODO: figure out best recbuf and/or support multiple recvs when they don't fit
    socket_opts = [
      :binary,
      active: false,
      recbuf: 65535
    ]

    # TODO: skip_database comes from Ecto.Adapters.MySQL, rethink this.
    skip_database? = Keyword.get(opts, :skip_database, false)
    database = if skip_database?, do: nil, else: database

    case :gen_tcp.connect(String.to_charlist(hostname), port, socket_opts, timeout) do
      {:ok, sock} ->
        state = %__MODULE__{sock: sock}
        handshake(state, username, password, database, ssl?, ssl_opts)

      {:error, reason} ->
        message = reason |> :inet.format_error() |> List.to_string()
        {:error, %MyXQL.Error{message: message}}
    end
  end

  @impl true
  def disconnect(_reason, s) do
    # TODO: see how postgrex does it
    :gen_tcp.close(s.sock)
    :ok
  end

  @impl true
  def checkout(state) do
    {:ok, state}
  end

  @impl true
  def checkin(state) do
    {:ok, state}
  end

  @impl true
  def handle_prepare(%Query{ref: ref, type: :binary} = query, _opts, s) when is_reference(ref) do
    data = encode_com_stmt_prepare(query.statement)
    data = send_and_recv(s, data)

    case decode_com_stmt_prepare_response(data) do
      com_stmt_prepare_ok(statement_id: statement_id) ->
        s = put_statement_id(s, query, statement_id)
        {:ok, query, s}

      err_packet(error_code: code, error_message: message) ->
        exception = %Error{message: message, query: query, mysql: %{code: code}}
        {:error, exception, s}
    end
  end

  defp maybe_reprepare(query, s) do
    case get_statement_id(query, s) do
      {:ok, statement_id} ->
        {query, statement_id, s}

      :error ->
        reprepare(query, s)
    end
  end

  @impl true
  def handle_execute(%Query{type: :binary} = query, params, _opts, s) do
    {query, statement_id, s} = maybe_reprepare(query, s)
    data = encode_com_stmt_execute(statement_id, params, :cursor_type_no_cursor)
    data = send_and_recv(s, data)

    case decode_com_stmt_execute_response(data) do
      resultset(column_definitions: column_definitions, rows: rows, status_flags: status_flags) ->
        columns = Enum.map(column_definitions, &elem(&1, 1))
        result = %Result{columns: columns, num_rows: length(rows), rows: rows}
        {:ok, query, result, update_status(s, status_flags)}

      ok_packet(
        status_flags: status_flags,
        affected_rows: affected_rows,
        last_insert_id: last_insert_id
      ) ->
        result = %Result{
          columns: [],
          rows: nil,
          num_rows: affected_rows,
          last_insert_id: last_insert_id
        }

        {:ok, query, result, update_status(s, status_flags)}

      err_packet(error_code: code, error_message: message) ->
        mysql = %{code: code, message: message}
        exception = %Error{message: message, query: query, mysql: mysql}
        {:error, exception, s}
    end
  end

  def handle_execute(%Query{type: :text, statement: statement} = query, [], _opts, s) do
    data = encode_com_query(statement)
    data = send_and_recv(s, data)

    case decode_com_query_response(data) do
      ok_packet(last_insert_id: last_insert_id) ->
        {:ok, query, %MyXQL.Result{last_insert_id: last_insert_id}, s}

      resultset(column_definitions: column_definitions, rows: rows) ->
        columns = Enum.map(column_definitions, &elem(&1, 1))
        {:ok, query, %MyXQL.Result{columns: columns, rows: rows}, s}

      err_packet(error_message: message) ->
        {:error, %MyXQL.Error{message: message}, s}
    end
  end

  @impl true
  def handle_close(_query, _opts, state) do
    # TODO: https://dev.mysql.com/doc/internals/en/com-stmt-close.html
    # TODO: return %MyXQL.Result{}
    result = nil
    {:ok, result, state}
  end

  @impl true
  def ping(state) do
    # TODO: https://dev.mysql.com/doc/internals/en/com-ping.html
    {:ok, state}
  end

  @impl true
  def handle_begin(opts, %{transaction_status: status} = s) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction when status == :idle ->
        handle_transaction("BEGIN", s)

      :savepoint when status == :transaction ->
        handle_transaction("SAVEPOINT myxql_savepoint", s)

      mode when mode in [:transaction, :savepoint] ->
        IO.inspect [mode: mode, status: status]
        {status, s}
    end
  end

  @impl true
  def handle_commit(opts, %{transaction_status: status} = s) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction when status == :transaction ->
        handle_transaction("COMMIT", s)

      :savepoint when status == :transaction ->
        handle_transaction("RELEASE SAVEPOINT myxql_savepoint", s)

      mode when mode in [:transaction, :savepoint] ->
        {status, s}
    end
  end

  @impl true
  def handle_rollback(opts, %{transaction_status: status} = s) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction when status == :transaction ->
        handle_transaction("ROLLBACK", s)

      :savepoint when status == :transaction ->
        rollback_release =
          "ROLLBACK TO SAVEPOINT myxql_savepoint; RELEASE SAVEPOINT myxql_savepoint"

        handle_transaction(rollback_release, s)

      mode when mode in [:transaction, :savepoint] ->
        {status, s}
    end
  end

  @impl true
  def handle_status(_opts, s) do
    {s.transaction_status, s}
  end

  @impl true
  def handle_declare(query, params, _opts, s) do
    cursor = %Cursor{params: params}
    {:ok, query, cursor, s}
  end

  @impl true
  def handle_fetch(query, %Cursor{params: params}, opts, s) do
    max_rows = Keyword.fetch!(opts, :max_rows)
    {_query, statement_id, s} = maybe_reprepare(query, s)

    case s.cursor do
      nil ->
        data = encode_com_stmt_execute(statement_id, params, :cursor_type_read_only)
        data = send_and_recv(s, data)

        case decode_com_stmt_execute_response(data) do
          resultset(column_definitions: column_definitions, rows: [], status_flags: status_flags) ->
            true = :server_status_cursor_exists in list_status_flags(status_flags)
            s = %{s | cursor: column_definitions}

            fetch(statement_id, column_definitions, max_rows, s)
        end

      column_definitions ->
        fetch(statement_id, column_definitions, max_rows, s)
    end
  end

  defp fetch(statement_id, column_definitions, max_rows, s) do
    data = encode_com_stmt_fetch(statement_id, max_rows, 0)
    data = send_and_recv(s, data)

    case data do
      <<_size::24-little, _seq, 0xFF, rest::binary>> ->
        err_packet(error_message: message) = decode_err_packet(<<0xFF>> <> rest)
        {:error, %MyXQL.Error{message: message}, %{s | cursor: nil}}

      _ ->
        {rows, _warning_count, status_flags} =
          decode_binary_resultset_rows(data, column_definitions, [])

        columns = Enum.map(column_definitions, &elem(&1, 1))
        result = %MyXQL.Result{rows: rows, num_rows: length(rows), columns: columns}

        if :server_status_cursor_exists in list_status_flags(status_flags) do
          {:cont, result, s}
        else
          {:halt, result, %{s | cursor: nil}}
        end
    end
  end

  # TODO: finish up
  @impl true
  def handle_deallocate(_query, %Cursor{}, _opts, s) do
    {:ok, nil, s}
  end

  ## Internals

  defp handshake(state, username, password, database, ssl?, ssl_opts) do
    {:ok, data} = :gen_tcp.recv(state.sock, 0)

    handshake_v10(
      conn_id: conn_id,
      auth_plugin_name: auth_plugin_name,
      auth_plugin_data1: auth_plugin_data1,
      auth_plugin_data2: auth_plugin_data2
    ) = MyXQL.Messages.decode_handshake_v10(data)

    state = %{state | connection_id: conn_id}
    sequence_id = 1

    case maybe_upgrade_to_ssl(state, ssl?, ssl_opts, database, sequence_id) do
      {:ok, state, sequence_id} ->
        auth_plugin_data = <<auth_plugin_data1::binary, auth_plugin_data2::binary>>

        do_handshake(
          state,
          username,
          password,
          auth_plugin_name,
          auth_plugin_data,
          database,
          sequence_id,
          ssl?
        )

      {:error, _} = error ->
        error
    end
  end

  defp do_handshake(
         state,
         username,
         password,
         auth_plugin_name,
         auth_plugin_data,
         database,
         sequence_id,
         ssl?
       ) do
    auth_response = auth_response(auth_plugin_name, password, auth_plugin_data)

    data =
      MyXQL.Messages.encode_handshake_response_41(
        username,
        auth_plugin_name,
        auth_response,
        database,
        ssl?,
        sequence_id
      )

    data = send_and_recv(state, data)

    case decode_handshake_response(data) do
      ok_packet(warning_count: 0) ->
        {:ok, state}

      err_packet(error_message: message) ->
        {:error, %MyXQL.Error{message: message}}

      auth_switch_request(plugin_name: plugin_name, plugin_data: plugin_data) ->
        with {:ok, auth_response} <-
               auth_switch_response(plugin_name, password, plugin_data, ssl?) do
          data = encode_packet(auth_response, sequence_id + 2)
          data = send_and_recv(state, data)

          case decode_handshake_response(data) do
            ok_packet(warning_count: 0) ->
              {:ok, state}

            err_packet(error_message: message) ->
              {:error, %MyXQL.Error{message: message}}
          end
        end

      :full_auth ->
        if ssl? do
          auth_response = password <> <<0x00>>
          data = encode_packet(auth_response, sequence_id + 2)
          data = send_and_recv(state, data)

          case decode_handshake_response(data) do
            ok_packet(warning_count: 0) ->
              {:ok, state}

            err_packet(error_message: message) ->
              {:error, %MyXQL.Error{message: message}}
          end
        else
          message =
            "ERROR 2061 (HY000): Authentication plugin 'caching_sha2_password' reported error: Authentication requires secure connection."

          {:error, %MyXQL.Error{message: message}}
        end
    end
  end

  defp auth_response(_plugin_name, nil, _plugin_data),
    do: nil

  defp auth_response("mysql_native_password", password, plugin_data),
    do: MyXQL.Utils.mysql_native_password(password, plugin_data)

  defp auth_response(plugin_name, password, plugin_data)
       when plugin_name in ["sha256_password", "caching_sha2_password"],
       do: MyXQL.Utils.sha256_password(password, plugin_data)

  defp auth_switch_response(_plugin_name, nil, _plugin_data, _ssl?),
    do: {:ok, <<>>}

  defp auth_switch_response("mysql_native_password", password, plugin_data, _ssl?),
    do: {:ok, MyXQL.Utils.mysql_native_password(password, plugin_data)}

  defp auth_switch_response(plugin_name, password, _plugin_data, ssl?)
       when plugin_name in ["sha256_password", "caching_sha2_password"] do
    if ssl? do
      # TODO: add test for empty password
      {:ok, (password || "") <> <<0x00>>}
    else
      # TODO: put error code into separate exception field
      message =
        "ERROR 2061 (HY000): Authentication plugin 'caching_sha2_password' reported error: Authentication requires secure connection."

      {:error, %MyXQL.Error{message: message}}
    end
  end

  defp maybe_upgrade_to_ssl(state, true, ssl_opts, database, sequence_id) do
    data = encode_ssl_request(sequence_id, database)
    :ok = :gen_tcp.send(state.sock, data)

    case :ssl.connect(state.sock, ssl_opts) do
      {:ok, ssl_sock} ->
        {:ok, %{state | sock: ssl_sock}, sequence_id + 1}

      {:error, reason} ->
        message = reason |> :ssl.format_error() |> List.to_string()
        {:error, %MyXQL.Error{message: message}}
    end
  end

  defp maybe_upgrade_to_ssl(state, false, _ssl_opts, _database, sequence_id) do
    {:ok, state, sequence_id}
  end

  defp send_and_recv(%{sock: sock}, data) when is_port(sock) do
    :ok = :gen_tcp.send(sock, data)
    {:ok, data} = :gen_tcp.recv(sock, 0)
    data
  end

  defp send_and_recv(%{sock: ssl_sock}, data) do
    :ok = :ssl.send(ssl_sock, data)
    {:ok, data} = :ssl.recv(ssl_sock, 0)
    data
  end

  defp handle_transaction(statement, s) do
    case send_text_query(s, statement) do
      ok_packet(status_flags: status_flags) ->
        result = :todo
        {:ok, result, update_status(s, status_flags)}

      err_packet(error_code: code, error_message: message) ->
        # TODO: do we need query here?
        exception = %Error{message: message, mysql: %{code: code}}
        {:disconnect, exception, s}
    end
  end

  defp send_text_query(s, statement) do
    data = encode_com_query(statement)
    data = send_and_recv(s, data)
    decode_com_query_response(data)
  end

  defp transaction_status(status_flags) do
    if has_status_flag?(status_flags, :server_status_in_trans) do
      :transaction
    else
      :idle
    end
  end

  defp update_status(s, status_flags) do
    %{s | transaction_status: transaction_status(status_flags)}
  end

  defp put_statement_id(s, %Query{ref: ref}, statement_id) do
    %{s | prepared_statements: Map.put(s.prepared_statements, ref, statement_id)}
  end

  defp get_statement_id(%Query{ref: ref}, s) do
    Map.fetch(s.prepared_statements, ref)
  end

  defp reprepare(query, s) do
    # TODO: extract common parts instead
    # TODO: handle error when it can't be prepared
    # TODO: return statement_id without additional lookup
    # TODO: we don't actually need to set new ref but that seems cleaner
    {:ok, query, s} = handle_prepare(query, [], s)
    {:ok, statement_id} = get_statement_id(query, s)
    query = %{query | ref: make_ref()}
    {query, statement_id, s}
  end
end
