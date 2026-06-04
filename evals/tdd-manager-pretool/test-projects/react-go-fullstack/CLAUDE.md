# React/Go Fullstack Test Project

npm workspaces monorepo: Frontend (React/TypeScript/Vitest) + Backend (Go).

## Tests
- All: `npm run test:all`
- Frontend: `npm --workspace frontend test`
- Backend: `cd backend && go test ./...`

## Build
- Frontend: `npm --workspace frontend run build`
- Backend: `cd backend && go build ./...`
