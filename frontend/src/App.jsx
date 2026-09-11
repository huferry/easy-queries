import { useEffect, useMemo, useRef, useState } from 'react'
import './App.css'

const API_BASE = import.meta.env.DEV
  ? 'http://localhost:5052'
  : (import.meta.env.VITE_API_BASE_URL ?? '')

const getInitialTheme = () => {
  const stored = localStorage.getItem('theme')
  if (stored === 'dark' || stored === 'light') return stored
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
}

function App() {
  const [theme, setTheme] = useState(getInitialTheme)
  const [databases, setDatabases] = useState([])
  const [selectedDatabase, setSelectedDatabase] = useState('')
  const [queries, setQueries] = useState([])
  const [selectedQuery, setSelectedQuery] = useState('')
  const [filterValues, setFilterValues] = useState({})
  const [maxResults, setMaxResults] = useState('500')
  const [result, setResult] = useState(null)
  const [sort, setSort] = useState({ columnIndex: null, direction: 'asc' })
  const [executing, setExecuting] = useState(false)
  const [error, setError] = useState(null)
  const [showSql, setShowSql] = useState(false)
  const [toastMessage, setToastMessage] = useState(null)
  const toastTimeoutRef = useRef(null)
  const [tableScrollWidth, setTableScrollWidth] = useState(0)
  const topScrollRef = useRef(null)
  const tableScrollRef = useRef(null)

  const filters = queries.find((q) => q.name === selectedQuery)?.filters ?? []

  useEffect(() => {
    document.documentElement.setAttribute('data-bs-theme', theme)
    localStorage.setItem('theme', theme)
  }, [theme])

  const toggleTheme = () => setTheme((prev) => (prev === 'dark' ? 'light' : 'dark'))

  const sortedRows = useMemo(() => {
    if (!result) return []
    if (sort.columnIndex === null) return result.rows

    const factor = sort.direction === 'asc' ? 1 : -1
    return [...result.rows].sort((a, b) => {
      const av = a[sort.columnIndex]
      const bv = b[sort.columnIndex]
      if (av === null && bv === null) return 0
      if (av === null) return 1
      if (bv === null) return -1
      if (av < bv) return -1 * factor
      if (av > bv) return 1 * factor
      return 0
    })
  }, [result, sort])

  const handleSort = (columnIndex) => {
    setSort((prev) => {
      if (prev.columnIndex !== columnIndex) return { columnIndex, direction: 'asc' }
      if (prev.direction === 'asc') return { columnIndex, direction: 'desc' }
      return { columnIndex: null, direction: 'asc' }
    })
  }

  useEffect(() => {
    const el = tableScrollRef.current
    if (!el) return

    const updateWidth = () => setTableScrollWidth(el.scrollWidth)
    updateWidth()

    const observer = new ResizeObserver(updateWidth)
    observer.observe(el)
    return () => observer.disconnect()
  }, [sortedRows])

  const handleTopScroll = () => {
    if (tableScrollRef.current && topScrollRef.current) {
      tableScrollRef.current.scrollLeft = topScrollRef.current.scrollLeft
    }
  }

  const handleTableScroll = () => {
    if (tableScrollRef.current && topScrollRef.current) {
      topScrollRef.current.scrollLeft = tableScrollRef.current.scrollLeft
    }
  }

  const showToast = (message) => {
    setToastMessage(message)
    if (toastTimeoutRef.current) clearTimeout(toastTimeoutRef.current)
    toastTimeoutRef.current = setTimeout(() => setToastMessage(null), 2000)
  }

  const handleCopyCell = (cell) => {
    const text = cell === null ? '' : String(cell)
    navigator.clipboard
      .writeText(text)
      .then(() => showToast('Value copied'))
      .catch(() => showToast('Copy failed'))
  }

  const handleCopySql = () => {
    navigator.clipboard
      .writeText(result?.sql ?? '')
      .then(() => showToast('SQL statement copied'))
      .catch(() => showToast('Copy failed'))
  }

  useEffect(() => {
    fetch(`${API_BASE}/api/databases`)
      .then((res) => {
        if (!res.ok) throw new Error(`Request failed: ${res.status}`)
        return res.json()
      })
      .then((data) => {
        setDatabases(data)
        setSelectedDatabase((current) => current || data[0] || '')
      })
      .catch((err) => setError(err.message))
  }, [])

  useEffect(() => {
    setResult(null)

    if (!selectedDatabase) {
      setQueries([])
      return
    }

    fetch(`${API_BASE}/api/queries?database=${encodeURIComponent(selectedDatabase)}`)
      .then((res) => {
        if (!res.ok) throw new Error(`Request failed: ${res.status}`)
        return res.json()
      })
      .then((data) => {
        setQueries(data)
        setSelectedQuery('')
        setFilterValues({})
      })
      .catch((err) => setError(err.message))
  }, [selectedDatabase])

  const handleSelectQuery = (queryName) => {
    setSelectedQuery(queryName)
    setFilterValues({})
  }

  const handleExecute = () => {
    if (!selectedQuery || !selectedDatabase) return

    setExecuting(true)
    setError(null)

    const filledFilters = Object.fromEntries(
      Object.entries(filterValues).filter(([, value]) => value.trim() !== '')
    )

    const parsedMaxResults = Number(maxResults)
    const maxResultsPayload =
      maxResults.trim() !== '' && Number.isFinite(parsedMaxResults) ? parsedMaxResults : undefined

    fetch(`${API_BASE}/api/queries/execute`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        name: selectedQuery,
        database: selectedDatabase,
        filters: filledFilters,
        maxResults: maxResultsPayload,
      }),
    })
      .then(async (res) => {
        const body = await res.json()
        if (!res.ok) throw new Error(body.message || `Request failed: ${res.status}`)
        return body
      })
      .then((data) => {
        setResult(data)
        setSort({ columnIndex: null, direction: 'asc' })
      })
      .catch((err) => setError(err.message))
      .finally(() => setExecuting(false))
  }

  return (
    <div className="d-flex flex-column flex-grow-1">
      <div className="d-flex justify-content-between align-items-center px-3 py-2 border-bottom">
        <span className="fw-semibold">Easy Quries</span>
        <button
          type="button"
          className="btn btn-sm btn-outline-secondary"
          onClick={toggleTheme}
          aria-label="Toggle dark mode"
        >
          {theme === 'dark' ? '☀️ Light' : '🌙 Dark'}
        </button>
      </div>

      <div className="container-fluid p-3 flex-grow-1">
      <div className="row align-items-start">
        <div className="col-3">
          <div className="mb-3 d-flex align-items-center gap-2">
            <label htmlFor="database-select" className="form-label mb-0 text-nowrap">
              Database
            </label>
            <select
              id="database-select"
              className="form-select"
              value={selectedDatabase}
              onChange={(e) => setSelectedDatabase(e.target.value)}
            >
              {databases.map((db) => (
                <option key={db} value={db}>
                  {db}
                </option>
              ))}
            </select>
          </div>

          <div className="card">
            <div className="card-header">Queries</div>
            <div className="list-group list-group-flush query-list">
              {queries.map((query) => (
                <button
                  key={query.name}
                  type="button"
                  className={`list-group-item list-group-item-action ${
                    selectedQuery === query.name ? 'active' : ''
                  }`}
                  onClick={() => handleSelectQuery(query.name)}
                >
                  {query.name}
                </button>
              ))}
            </div>
            {selectedQuery && (
              <div className="card-body border-top">
                <div className="row mb-2 gx-2 align-items-center">
                  <label
                    htmlFor="filter-max-results"
                    className="col-5 col-form-label col-form-label-sm text-end"
                  >
                    max results
                  </label>
                  <div className="col-7">
                    <div className="input-group input-group-sm">
                      <input
                        id="filter-max-results"
                        type="number"
                        min="1"
                        className="form-control"
                        value={maxResults}
                        onChange={(e) => setMaxResults(e.target.value)}
                      />
                      <button
                        type="button"
                        className="btn btn-outline-secondary"
                        aria-label="Clear max results"
                        onClick={() => setMaxResults('')}
                      >
                        ×
                      </button>
                    </div>
                  </div>
                </div>
                {filters.map((filter) => (
                  <div className="row mb-2 gx-2 align-items-center" key={filter.name}>
                    <label
                      htmlFor={`filter-${filter.name}`}
                      className="col-5 col-form-label col-form-label-sm text-end"
                    >
                      {filter.name}
                    </label>
                    <div className="col-7">
                      <div className="input-group input-group-sm">
                        <input
                          id={`filter-${filter.name}`}
                          type="text"
                          className="form-control"
                          list={filter.options.length > 0 ? `filter-options-${filter.name}` : undefined}
                          value={filterValues[filter.name] ?? ''}
                          onChange={(e) =>
                            setFilterValues((prev) => ({ ...prev, [filter.name]: e.target.value }))
                          }
                        />
                        {filter.options.length > 0 && (
                          <datalist id={`filter-options-${filter.name}`}>
                            {filter.options.map((option) => (
                              <option key={option} value={option} />
                            ))}
                          </datalist>
                        )}
                        <button
                          type="button"
                          className="btn btn-outline-secondary"
                          aria-label={`Clear ${filter.name}`}
                          onClick={() =>
                            setFilterValues((prev) => ({ ...prev, [filter.name]: '' }))
                          }
                        >
                          ×
                        </button>
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            )}
            <div className="card-footer">
              <button
                type="button"
                className="btn btn-primary w-100"
                disabled={!selectedQuery || executing}
                onClick={handleExecute}
              >
                {executing ? 'Executing…' : 'Execute'}
              </button>
            </div>
          </div>
        </div>

        <div className="col-9">
          <div className="card">
            <div className="card-header d-flex justify-content-between align-items-center">
              <span>Result</span>
              {result?.sql && (
                <span
                  className="sql-info position-relative"
                  onMouseEnter={() => setShowSql(true)}
                  onMouseLeave={() => setShowSql(false)}
                >
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    width="18"
                    height="18"
                    fill="currentColor"
                    viewBox="0 0 16 16"
                    role="img"
                    aria-label="Copy executed SQL to clipboard"
                    onClick={handleCopySql}
                  >
                    <path d="M8 16A8 8 0 1 0 8 0a8 8 0 0 0 0 16zm.93-9.412-1 4.705c-.07.34.029.533.304.533.194 0 .487-.07.686-.246l-.088.416c-.287.346-.92.598-1.465.598-.703 0-1.002-.422-.808-1.319l.738-3.468c.064-.293.006-.399-.287-.47l-.451-.081.082-.381 2.29-.287zM8 5.5a1 1 0 1 1 0-2 1 1 0 0 1 0 2z" />
                  </svg>
                  {showSql && (
                    <div className="sql-popover shadow">
                      <pre className="mb-0">{result.sql}</pre>
                    </div>
                  )}
                </span>
              )}
            </div>
            <div className="card-body result-body">
              {error && <div className="alert alert-danger">{error}</div>}
              {result && (
                <>
                  <div
                    className="top-scroll"
                    ref={topScrollRef}
                    onScroll={handleTopScroll}
                  >
                    <div style={{ width: tableScrollWidth, height: 1 }} />
                  </div>
                  <div
                    className="table-responsive"
                    ref={tableScrollRef}
                    onScroll={handleTableScroll}
                  >
                  <table className="table table-striped table-bordered table-sm result-table">
                    <thead>
                      <tr>
                        {result.columns.map((column, columnIndex) => (
                          <th
                            key={column.name}
                            className="sortable-header"
                            onClick={() => handleSort(columnIndex)}
                          >
                            {column.name}
                            {sort.columnIndex === columnIndex && (
                              <span>{sort.direction === 'asc' ? ' ▲' : ' ▼'}</span>
                            )}
                            <br />
                            <small className="text-muted fw-normal">{column.type}</small>
                          </th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {sortedRows.map((row, rowIndex) => (
                        <tr key={rowIndex}>
                          {row.map((cell, cellIndex) => (
                            <td
                              key={cellIndex}
                              className="copyable-cell"
                              title={cell === null ? '' : String(cell)}
                              onClick={() => handleCopyCell(cell)}
                            >
                              {cell === null ? (
                                <span className="text-muted fst-italic">NULL</span>
                              ) : (
                                String(cell)
                              )}
                            </td>
                          ))}
                        </tr>
                      ))}
                    </tbody>
                  </table>
                  {sortedRows.length === 0 && (
                    <p className="text-muted">Query returned no rows.</p>
                  )}
                  </div>
                </>
              )}
            </div>
          </div>
        </div>
      </div>

      {toastMessage && <div className="app-toast shadow">{toastMessage}</div>}
      </div>
    </div>
  )
}

export default App
