# apple-pv-detector

A small tool that detects a specific **Apple Paravirtual Metal rendering bug** on arm64 macOS.

It checks actual GPU rendering behavior instead of relying on system information, device names, or driver checks.

## Requirements

- macOS on arm64 (Apple Silicon)
- Xcode Command Line Tools (`xcode-select --install`)
- No administrator privileges required

## Run

```bash
bash apple-pv-detector/run.sh
```

The script automatically compiles, runs, and cleans up the detector.

To keep the compiled executable:

```bash
xcrun swiftc -O -target arm64-apple-macos11.0 -framework Metal apple-pv-detector/probe.swift -o /tmp/apple-pv-detector
/tmp/apple-pv-detector
```

## How It Works

The detector tests whether the GPU incorrectly truncates an index-buffer offset.

It:

1. Places different index data at offsets `0` and `65536`.
2. Compares compact and forced-wide indexed draws.
3. Checks GPU readback and reference renders to validate results.
4. Reports the bug only when both compact draws use the wrong data while the wide controls work correctly.

## Results

| Exit code | Result | Meaning |
|---|---|---|
| `0` | `DETECTED` | The rendering bug was found. |
| `1` | `NOT_DETECTED` | Both compact draws rendered correctly. |
| `2` | `UNKNOWN` | The test couldn't produce a reliable result. |
