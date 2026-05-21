# React/Go Fullstack Test-Projekt

npm workspaces monorepo: Frontend (React/TypeScript/Vitest) + Backend (Go).

## Tests
- Komplett: `npm run test:all`
- Frontend: `npm --workspace frontend test`
- Backend: `cd backend && go test ./...`

## Build
- Frontend: `npm --workspace frontend run build`
- Backend: `cd backend && go build ./...`
