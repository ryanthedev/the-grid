# Development Guidelines

## Priority: Build First, Validate Second
- Focus on implementing working code that meets requirements
- Skip comprehensive documentation unless explicitly requested
- No e2e tests unless specifically asked

## Testing Strategy
- Write minimal unit tests only to validate core logic/assumptions
- 3-5 targeted tests maximum per feature
- It's acceptable to create temporary tests and delete them after validation
- Tests should prove the approach works, not provide coverage

## Logging Requirements
- Use structured logging (JSON format preferred)
- Log at critical decision points and state changes
- Include relevant context: operation, input state, output state, errors
- Examples:
  - Before/after major transformations
  - Error conditions with full context
  - External API calls (request/response)

## Project Paths
- **Log files**: `~/.local/state/thegrid/`
  - `grid-cli.log` - CLI client logs (JSON structured)
  - `grid-server.log` - Server logs
  - `state.json` - Runtime state
- **Config**: `~/.config/thegrid/config.yaml`
- **Server socket**: `/tmp/grid-server.sock`

## Documentation Research
- ALWAYS search online for API docs, library usage examples
- Run `--help`, `man`, or equivalent for CLI tools before using
- Verify syntax and options rather than assuming
- Check official docs for breaking changes

## Response Style
- Keep explanations concise
- Code first, explanation after
- No apologetic language or over-explaining
