defmodule Ch.ExternalTable do
  @moduledoc """
  A temporary table sent along with a query as
  [external data](https://clickhouse.com/docs/engines/table-engines/special/external-data).

  External tables are useful when a query needs a large set of values, for example
  filtering by hundreds of thousands or millions of ids. Such sets are too big for
  query parameters: URL parameters are limited by the maximum URL length and each
  `multipart: true` parameter is limited by the maximum size of a form field.

  Pass external tables to `Ch.query/4` with the `:external` option. ClickHouse makes each
  table available under its name for the duration of that one query only:

      ids = [[1], [2], [3]]
      ids_table = Ch.ExternalTable.new(:ids, [id: "UInt64"], ids)

      Ch.query!(
        pool,
        "SELECT count() FROM events WHERE user_id IN ids AND site_id = {site_id:UInt64}",
        %{"site_id" => 1},
        external: [ids_table]
      )

  External tables are sent as files in a `multipart/form-data` request body, so the
  `:external` option implies `multipart: true`. Query parameters are sent in the
  same body and keep working as usual.

  The request body can't hold both external tables and INSERT data. To insert the rows of
  an external table, use `INSERT INTO table SELECT ... FROM external_table`.

  > #### Name collisions {: .warning}
  >
  > An external table hides any real table with the same name in the current database,
  > without an error. Pick names that don't collide with tables the query reads,
  > or qualify real tables with their database name.
  """

  alias Ch.RowBinary

  @enforce_keys [:name, :structure, :format, :data]
  defstruct [:name, :structure, :format, :data]

  @typedoc """
  An external table.

  ## Fields

    * `:name` - The table name used in the query.
    * `:structure` - The table structure, e.g. `"id UInt64, name String"`.
    * `:format` - The ClickHouse format of `:data`, e.g. `"RowBinary"` or `"CSV"`.
    * `:data` - The encoded table data.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          structure: String.t(),
          format: String.t(),
          data: iodata
        }

  @doc """
  Builds an external table from rows, encoded with `Ch.RowBinary`.

  `columns` is a keyword list (or a list of `{name, type}` tuples) of column names and
  ClickHouse types, e.g. `[id: "UInt64", name: "String"]`. The types are the same as
  the ones accepted by `Ch.RowBinary.encode_rows/2`.

  `rows` is a list of rows, where each row is a list of column values in the order of
  `columns`. The rows are encoded right away.

  ## Examples

      Ch.ExternalTable.new(:ids, [id: "UInt64"], [[1], [2], [3]])

  """
  @spec new(atom | String.t(), [{atom | String.t(), String.t() | atom | tuple}], [[term]]) :: t
  def new(name, columns, rows) when is_list(columns) and is_list(rows) do
    name = validate_name!(name)
    structure = Enum.map_join(columns, ", ", &column_definition/1)
    types = Enum.map(columns, fn {_name, type} -> type end)
    data = RowBinary.encode_rows(rows, types)
    %__MODULE__{name: name, structure: structure, format: "RowBinary", data: data}
  end

  @doc """
  Builds an external table from data that is already encoded in any
  [ClickHouse input format](https://clickhouse.com/docs/interfaces/formats).

  `structure` is the table structure as ClickHouse column definitions, e.g.
  `"id UInt64, name String"`, and `format` is the format of `data`, e.g. `"CSV"`,
  `"TabSeparated"`, `"RowBinary"`, or `"Parquet"`.

  `data` is the encoded data as `t:iodata/0`.

  ## Examples

      Ch.ExternalTable.raw(:ids, "id UInt64", "CSV", "1\\n2\\n3\\n")

      Ch.ExternalTable.raw(:ids, "id UInt64", "CSV", File.read!("ids.csv"))

  """
  @spec raw(atom | String.t(), String.t(), String.t(), iodata) :: t
  def raw(name, structure, format, data)
      when is_binary(structure) and is_binary(format) and (is_binary(data) or is_list(data)) do
    %__MODULE__{name: validate_name!(name), structure: structure, format: format, data: data}
  end

  defp column_definition({name, type}) do
    type = if is_binary(type), do: type, else: Ch.Types.encode(type)
    escaped = String.replace(to_string(name), ["\\", "`"], &("\\" <> &1))
    [?`, escaped, "` ", type]
  end

  # The name is used in the `content-disposition` header of the multipart body
  # and in the `<name>_structure` and `<name>_format` URL parameters.
  defp validate_name!(name) when is_atom(name) and name not in [nil, true, false] do
    validate_name!(Atom.to_string(name))
  end

  defp validate_name!(name) when is_binary(name) do
    if name =~ ~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/, do: name, else: invalid_name!(name)
  end

  defp validate_name!(name), do: invalid_name!(name)

  defp invalid_name!(name) do
    raise ArgumentError,
          "external table name must be an atom or a string that starts with a letter or " <>
            "an underscore and contains only letters, digits, and underscores, got: #{inspect(name)}"
  end
end
