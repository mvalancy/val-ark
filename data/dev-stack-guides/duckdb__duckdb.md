# DuckDB

A database in a single program, built for analysing data: point it at CSV, Parquet or
JSON files and ask questions in SQL. Nothing to set up and no server to run.

## Install

The command line program is in the `duckdb-cli-*` files (older releases: `duckdb_cli-*`):
`-linux-amd64`, `-linux-arm64`, `-osx-universal` (macOS), `-windows-amd64`.

```
tar xzf duckdb-cli-linux-amd64.tar.gz      # or: unzip duckdb-cli-linux-amd64.zip
sudo mv duckdb /usr/local/bin/
duckdb --version
```

The `libduckdb-*` and `static-libs` files are for programmers, not needed to use it.

## First steps offline

```
duckdb mydata.db
```

That opens (or creates) a database file. Then, at the prompt:

```
SELECT * FROM 'sales.csv' LIMIT 10;
CREATE TABLE sales AS SELECT * FROM 'sales.csv';
SELECT region, sum(amount) FROM sales GROUP BY region;
COPY sales TO 'sales.parquet';
.quit
```

Run `duckdb` with no file name for a scratch database that lives in memory.

## Extensions need the internet

CSV, Parquet and JSON are built in. Other features (`httpfs`, `spatial`, `sqlite`, ...) are
extensions that DuckDB downloads the first time you use them, so offline they fail with a
download error. The Ark does not mirror the extension files yet.

If you have an extension file from elsewhere (it must match your DuckDB version and
platform exactly), load it directly:

```
INSTALL '/path/to/httpfs.duckdb_extension';
LOAD httpfs;
```
