# Easy Quries

A small tool for browsing a set of predefined SQL queries, running them against a chosen SQL Server database, and viewing the results in the browser.

- **backend/EasyQueries.Api** — .NET 10 minimal API
- **frontend** — React + Vite, styled with Bootstrap

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Node.js](https://nodejs.org/) (v20+) and npm
- Access to a SQL Server instance

## Setup

### 1. Backend connection string

The connection string is kept out of source control. Create `backend/EasyQueries.Api/appsettings.Development.json` (it's git-ignored) with:

```json
{
  "ConnectionStrings": {
    "database": "Server=your-server;Database=YourDefaultDatabase;Integrated Security=True;Encrypt=True;MultipleActiveResultSets=True"
  }
}
```

The `Database` in this connection string is only used as the initial/default catalog — when a query is executed, the API reconnects with `Initial Catalog` set to whichever database was selected in the UI.

### 2. Query data files

Query definitions and the favorites list also live outside source control, under a `data/` folder (git-ignored, since its contents are environment/customer-specific). Create it at the repo root:

```
data/
  favorites.json
  queries/
    <any-name>.sql
```

By default the API looks for this folder two levels up from the backend project (`backend/EasyQueries.Api/../../data`, i.e. `<repo-root>/data`). To point it somewhere else instead, set `DataDirectory` in `appsettings.json` (or `appsettings.Development.json`) to an absolute path, or a path relative to the backend project folder:

```json
{
  "DataDirectory": "D:/shared/easy-queries-data"
}
```

#### favorites.json

A plain array of database names shown in the "Database" dropdown by default (`GET /api/databases` with `isFavorite=true`, the default):

```json
["VXStart", "VX_SalesDemo_Ferry_Utomo"]
```

#### Query files (`data/queries/*.sql`)

Each `.sql` file under `data/queries` becomes one entry in the query list. Metadata is written as SQL line comments mixed in with the query itself:

- `-- #name: <label>` — the display name shown in the Queries list. Defaults to the filename if omitted.
- `-- #db: <pattern>` — which database name(s) this query applies to. Supports `*` as a wildcard, and can be repeated for multiple patterns. A query only shows up (and can only be executed) for databases matching one of these patterns.
- `-- # [paramName] | <where-clause fragment>` — an optional filter. `paramName` becomes both the filter's label in the UI and the placeholder token you can use inside the clause fragment. Repeat this line once per filter.

Example — `data/queries/idp-domeinen.sql`:

```sql
-- #db: VXStart
-- #name: IDP Domeinen
SELECT TOP (1000) [Id]
      ,[Domein]
      ,[Type]
      ,[SkinName]
      ,[Disabled]
  FROM [VXStart].[dbo].[tblIDPDomeinen]
-- # [domein] | domein like '[domein]%'
-- # [disabled] | disabled = [disabled]
-- # [skin] | SkinName = [skin]
```

Notes on writing filters:

- Only filters the user actually fills in are applied; empty ones are skipped.
- Multiple applied filters are combined with `AND`, and `WHERE` is added automatically (or `AND` if the query already has a `WHERE`).
- Values are quoted automatically unless they're purely numeric, and single quotes in the value are always escaped — so it's safe to write a filter clause with or without literal quotes around the placeholder (e.g. `SkinName = [skin]` vs. `domein like '[domein]%'`, as shown above).
- Any `[Database].` qualifier in front of a `[schema].[table]` reference (e.g. `[VXStart].[dbo].[tblIDPDomeinen]`) is stripped before execution, so the same query file can be reused across multiple databases matched by a wildcard `#db` pattern — it always runs against whichever database was selected in the UI.
- A `TOP (n)` clause is added or replaced automatically based on the "max results" field in the UI.

A second example using a wildcard `#db` pattern so the same query works against several similarly-shaped databases — `data/queries/employer.sql`:

```sql
-- #name: Employer
-- #db: VX_SalesDemo*

SELECT [RefId]
      ,[EmployerId]
  FROM [VX_SalesDemo_Ferry_Utomo].[cx].[Employer]
```

## Running the application

**Backend** (from `backend/EasyQueries.Api`):

```bash
dotnet run
```

Listens on `http://localhost:5052` by default.

**Frontend** (from `frontend`, in a separate terminal):

```bash
npm install
npm run dev
```

Open `http://localhost:5173` in your browser. Start the backend first (or before loading the page), since the frontend fetches from it on load.
