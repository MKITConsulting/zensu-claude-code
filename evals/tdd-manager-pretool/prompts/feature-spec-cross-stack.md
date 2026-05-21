Two-step feature:
1. Frontend: `debounce<T>(fn, ms)` at `frontend/src/utils/debounce.ts` with vitest test.
2. Backend: `GenerateToken(userID string) (string, error)` at `backend/internal/auth/token.go` with Go test.
Strict RED -> IMPL -> GREEN for each. Independent steps — implement in either order, but both must end in GREEN_PASS.
