defmodule Ch.ExternalTableTest do
  use ExUnit.Case, async: true
  alias Ch.{ExternalTable, Query, RowBinary}

  describe "new/3" do
    test "encodes a list of rows with RowBinary" do
      rows = [[1, "a"], [2, "b"]]
      table = ExternalTable.new(:ids, [id: "UInt64", name: :string], rows)

      assert %ExternalTable{
               name: "ids",
               structure: "`id` UInt64, `name` String",
               format: "RowBinary"
             } =
               table

      assert IO.iodata_to_binary(table.data) ==
               IO.iodata_to_binary(RowBinary.encode_rows(rows, ["UInt64", "String"]))
    end

    test "quotes column names" do
      table = ExternalTable.new(:t, [{"my id", "UInt8"}, {"a`b\\c", "String"}], [])
      assert table.structure == "`my id` UInt8, `a\\`b\\\\c` String"
    end
  end

  describe "raw/4" do
    test "keeps the data as is" do
      assert %ExternalTable{name: "ids", structure: "id UInt64", format: "CSV", data: "1\n2\n"} =
               ExternalTable.raw(:ids, "id UInt64", "CSV", "1\n2\n")
    end
  end

  test "validates table names" do
    for name <- [:ids, "ids", "_ids", "IDS_2"] do
      assert %ExternalTable{} = ExternalTable.raw(name, "id UInt64", "CSV", "")
      assert %ExternalTable{} = ExternalTable.new(name, [id: "UInt64"], [])
    end

    for name <- [
          "",
          "1ids",
          "my-ids",
          "ids\"; filename=\"x",
          "ids\r\n",
          "ids&a=b",
          "ìds",
          :"a b",
          nil,
          true,
          false,
          1
        ] do
      assert_raise ArgumentError, ~r/external table name/, fn ->
        ExternalTable.raw(name, "id UInt64", "CSV", "")
      end

      assert_raise ArgumentError, ~r/external table name/, fn ->
        ExternalTable.new(name, [id: "UInt64"], [])
      end
    end
  end

  describe "query" do
    test "external tables imply multipart" do
      table = ExternalTable.new(:ids, [id: "UInt64"], [])

      assert %Query{multipart: true, external: [^table]} =
               Query.build("select 1", external: [table])

      assert %Query{multipart: true} = Query.build("select 1", external: [table], multipart: true)
      assert %Query{multipart: false, external: []} = Query.build("select 1", external: [])
    end

    test "external tables can't be used with multipart: false" do
      table = ExternalTable.new(:ids, [id: "UInt64"], [])

      assert_raise ArgumentError, ~r/can't be used with `multipart: false`/, fn ->
        Query.build("select 1", external: [table], multipart: false)
      end
    end

    test "external: nil means no external tables" do
      assert %Query{multipart: false, external: []} = Query.build("select 1", external: nil)
      assert %Query{multipart: true} = Query.build("select 1", external: nil, multipart: true)
    end

    test "external option must be a list of external tables" do
      assert_raise ArgumentError, ~r/expected :external to be a list/, fn ->
        Query.build("select 1", external: [{:ids, [1, 2]}])
      end

      assert_raise ArgumentError, ~r/expected :external to be a list/, fn ->
        Query.build("select 1", external: ExternalTable.new(:ids, [id: "UInt64"], []))
      end

      assert_raise ArgumentError, ~r/expected :external to be a list/, fn ->
        Query.build("select 1", external: :ids, multipart: false)
      end
    end
  end

  describe "encode" do
    test "sends tables as files in the multipart body and their structure in the URL" do
      ids = ExternalTable.new(:ids, [id: "UInt8"], [[1], [2]])
      names = ExternalTable.raw("names", "name String", "CSV", "a\nb\n")
      sql = "select * from ids, names where id = {id:UInt8}"
      query = Query.build(sql, external: [ids, names])

      {query_params, headers, body} = DBConnection.Query.encode(query, %{"id" => 1}, [])

      assert query_params == [
               {"ids_structure", "`id` UInt8"},
               {"ids_format", "RowBinary"},
               {"names_structure", "name String"},
               {"names_format", "CSV"}
             ]

      assert IO.iodata_to_binary(body) ==
               multipart_body(headers, [
                 {~s[name="param_id"], "1"},
                 {~s[name="query"], sql},
                 {~s[name="ids"; filename="ids"], <<1, 2>>},
                 {~s[name="names"; filename="names"], "a\nb\n"}
               ])
    end

    test "sends INSERT ... SELECT with a multipart body" do
      ids = ExternalTable.new(:ids, [id: "UInt8"], [[1]])
      sql = "insert into t select id from ids"
      query = Query.build(sql, external: [ids])
      assert query.command == :insert

      {query_params, headers, body} = DBConnection.Query.encode(query, [], [])

      assert query_params == [{"ids_structure", "`id` UInt8"}, {"ids_format", "RowBinary"}]

      assert IO.iodata_to_binary(body) ==
               multipart_body(headers, [
                 {~s[name="query"], sql},
                 {~s[name="ids"; filename="ids"], <<1>>}
               ])
    end
  end

  describe "INSERT data" do
    setup do
      {:ok, external: [ExternalTable.new(:ids, [id: "UInt8"], [[1]])]}
    end

    test "can't be sent with external tables", %{external: external} do
      inserts = [
        {"insert into t format RowBinary", [[1]], [types: ["UInt8"]]},
        {"insert into t format RowBinaryWithNamesAndTypes", [[1]],
         [names: ["id"], types: ["UInt8"]]},
        {"insert into t format CSV", "1\n", [encode: false]},
        {"insert into t format CSV", Stream.map(["1\n"], & &1), [encode: false]}
      ]

      for {sql, data, opts} <- inserts do
        query = Query.build(sql, [external: external] ++ opts)

        assert_raise ArgumentError, ~r/can't be sent with INSERT data/, fn ->
          DBConnection.Query.encode(query, data, opts)
        end
      end
    end

    test "can't be collected with external tables", %{external: external} do
      # Collectable Ch.stream sends the collected chunks after the encoded body
      for sql <- ["insert into t format CSV", "insert into t select id from ids"] do
        query = Query.build(sql, external: external, encode: false)

        assert_raise ArgumentError, ~r/can't be sent with INSERT data/, fn ->
          DBConnection.Query.encode(query, {:stream, []}, [])
        end
      end
    end
  end

  describe "ClickHouse" do
    setup do
      {:ok, conn: start_supervised!({Ch, database: Ch.Test.database()})}
    end

    test "filters by a list of ids", %{conn: conn} do
      ids = ExternalTable.new(:ids, [id: "UInt64"], Enum.map(1..100_000//2, &[&1]))

      assert %{rows: [[45_000, 2_475_000_000]]} =
               Ch.query!(
                 conn,
                 "SELECT count(), sum(number) FROM numbers({n:UInt64}) WHERE number > {min:UInt64} AND number IN ids",
                 %{"n" => 1_000_000, "min" => 10_000},
                 external: [ids]
               )
    end

    @tag :slow
    test "filters by a million ids", %{conn: conn} do
      ids = ExternalTable.new(:ids, [id: "UInt64"], Enum.map(1..2_000_000//2, &[&1]))

      assert %{rows: [[1_000_000]]} =
               Ch.query!(
                 conn,
                 "SELECT count() FROM numbers(3000000) WHERE number IN ids",
                 [],
                 external: [ids]
               )
    end

    test "empty table", %{conn: conn} do
      ids = ExternalTable.new(:ids, [id: "UInt64"], [])

      assert %{rows: [[0]]} =
               Ch.query!(conn, "SELECT count() FROM numbers(10) WHERE number IN ids", [],
                 external: [ids]
               )
    end

    test "joins multiple tables", %{conn: conn} do
      users = ExternalTable.new(:users, [id: "UInt32", name: "String"], [[1, "ann"], [2, "bob"]])

      visits =
        ExternalTable.new(:visits, [user_id: "UInt32", page: "String"], [
          [1, "/a"],
          [2, "/b"],
          [1, "/c"],
          [3, "/d"]
        ])

      assert %{rows: [["ann", ["/a", "/c"]], ["bob", ["/b"]]]} =
               Ch.query!(
                 conn,
                 """
                 SELECT users.name, arraySort(groupArray(visits.page))
                 FROM visits JOIN users ON users.id = visits.user_id
                 GROUP BY users.name ORDER BY users.name
                 """,
                 [],
                 external: [users, visits]
               )
    end

    test "raw CSV", %{conn: conn} do
      csv = "1,\"hello, world\"\n2,\"bye\"\n"

      table = ExternalTable.raw(:t, "id UInt8, s String", "CSV", csv)

      assert %{rows: [[1, "hello, world"], [2, "bye"]]} =
               Ch.query!(conn, "SELECT * FROM t ORDER BY id", [], external: [table])
    end

    test "raises ArgumentError with multipart: false", %{conn: conn} do
      ids = ExternalTable.new(:ids, [id: "UInt64"], [[1]])

      assert_raise ArgumentError, ~r/multipart: false/, fn ->
        Ch.query(conn, "SELECT * FROM ids", [], external: [ids], multipart: false)
      end
    end

    test "INSERT ... SELECT from an external table", %{conn: conn} do
      table = "external_insert_#{System.unique_integer([:positive])}"
      Ch.query!(conn, "CREATE TABLE #{table}(id UInt64, s String) ENGINE Memory")
      on_exit(fn -> Ch.Test.query("DROP TABLE #{table}") end)

      rows = ExternalTable.new(:rows, [id: "UInt64", s: "String"], [[1, "a"], [2, "b"]])

      Ch.query!(
        conn,
        "INSERT INTO {table:Identifier} SELECT id, concat(s, {suffix:String}) FROM rows",
        %{"table" => table, "suffix" => "!"},
        external: [rows]
      )

      assert %{rows: [[1, "a!"], [2, "b!"]]} =
               Ch.query!(conn, "SELECT * FROM #{table} ORDER BY id")
    end

    test "quoted column names", %{conn: conn} do
      table = ExternalTable.new(:t, [{"my id", "UInt8"}, {"a`b", "String"}], [[1, "x"]])

      assert %{columns: ["my id", "a`b"], rows: [[1, "x"]]} =
               Ch.query!(conn, "SELECT * FROM t", [], external: [table])
    end

    test "INSERT with data and external tables raises before sending", %{conn: conn} do
      table = "external_insert_data_#{System.unique_integer([:positive])}"
      Ch.query!(conn, "CREATE TABLE #{table}(id UInt8) ENGINE Memory")
      on_exit(fn -> Ch.Test.query("DROP TABLE #{table}") end)
      ids = ExternalTable.new(:ids, [id: "UInt8"], [[1]])

      assert_raise ArgumentError, fn ->
        Ch.query(conn, "INSERT INTO #{table} FORMAT RowBinary", [[2]],
          types: ["UInt8"],
          external: [ids]
        )
      end

      assert_raise ArgumentError, fn ->
        DBConnection.run(conn, fn conn ->
          Enum.into(
            [<<3>>],
            Ch.stream(conn, "INSERT INTO #{table} FORMAT RowBinary", [], external: [ids])
          )
        end)
      end

      assert %{rows: []} = Ch.query!(conn, "SELECT * FROM #{table}")
    end

    test "hides a real table with the same name", %{conn: conn} do
      table = "external_hidden_#{System.unique_integer([:positive])}"
      Ch.query!(conn, "CREATE TABLE #{table}(id UInt64) ENGINE Memory")
      on_exit(fn -> Ch.Test.query("DROP TABLE #{table}") end)
      Ch.query!(conn, "INSERT INTO #{table} VALUES (1)")

      external = ExternalTable.new(table, [id: "UInt64"], [[2]])

      assert %{rows: [[2]]} = Ch.query!(conn, "SELECT * FROM #{table}", [], external: [external])
      assert %{rows: [[1]]} = Ch.query!(conn, "SELECT * FROM #{table}")
    end

    test "Ch.stream", %{conn: conn} do
      ids = ExternalTable.new(:ids, [id: "UInt64"], [[1], [2], [3]])

      rows =
        DBConnection.run(conn, fn conn ->
          conn
          |> Ch.stream("SELECT id * 2 FROM ids ORDER BY id", [], external: [ids])
          |> Enum.flat_map(& &1.rows)
        end)

      assert rows == [[2], [4], [6]]
    end
  end

  defp multipart_body(headers, parts) do
    {"content-type", "multipart/form-data; boundary=\"" <> boundary} =
      List.keyfind(headers, "content-type", 0)

    boundary = String.trim_trailing(boundary, "\"")

    parts =
      Enum.map(parts, fn {disposition, value} ->
        "--#{boundary}\r\ncontent-disposition: form-data; #{disposition}\r\n\r\n#{value}\r\n"
      end)

    IO.iodata_to_binary([parts, "--#{boundary}--\r\n"])
  end
end
