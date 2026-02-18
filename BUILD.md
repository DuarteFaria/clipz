# Clipz Build Guide (gpui)

## Prerequisites
- Zig 0.13.0+ for the backend
- Rust stable for the gpui frontend

## Build steps
```bash
# Backend
zig build

# Frontend (macOS)
cargo build -p clipz-gpui
```

## Running
```bash
# CLI
./zig-out/bin/clipz

# gpui frontend (launches backend in JSON mode)
cargo run -p clipz-gpui
```

## Packaging status
Electron packaging has been removed. Native gpui packaging is not yet wired up; plan for a macOS bundle that embeds `clipz` and the Rust binary.

## Testing checklist
- Clipboard monitoring and history persistence in Zig backend
- gpui list rendering, search, select, remove, clear actions
- JSON API responses match UI expectations