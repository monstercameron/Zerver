# Deployment Guide

This document provides minimal deployment notes for Zerver applications.

## Prerequisites

- Zig 0.15.0 or higher
- Target platform support (Linux, macOS, Windows)

## Building

### Development Build
```bash
zig build
```

### Optimized Release Build
```bash
zig build -Doptimize=ReleaseFast
```

### Cross-Compilation
```bash
# Linux x86_64
zig build -Dtarget=x86_64-linux-gnu

# Windows x86_64
zig build -Dtarget=x86_64-windows-gnu

# macOS x86_64
zig build -Dtarget=x86_64-macos-gnu

# macOS ARM64
zig build -Dtarget=aarch64-macos-gnu
```

## Running

### Basic Execution
```bash
# Run the built executable
./zig-out/bin/zerver_example
```

### With Configuration
```bash
# Using environment variables
export ZERVER_HOST=0.0.0.0
export ZERVER_PORT=8080
./zig-out/bin/zerver_example
```

### Development Mode
```bash
# Run with debug logging
zig build run
```

## Deployment Options

### 1. Standalone Binary
- Build optimized binary: `zig build -Doptimize=ReleaseFast`
- Copy `zig-out/bin/zerver_example` to server
- Run directly: `./zerver_example`

### 2. Docker Container
```dockerfile
FROM alpine:latest
RUN apk add --no-cache ca-certificates
COPY zig-out/bin/zerver_example /usr/local/bin/zerver
EXPOSE 8080
CMD ["/usr/local/bin/zerver"]
```

### 3. Systemd Service
```ini
[Unit]
Description=Zerver Application
After=network.target

[Service]
Type=simple
User=zerver
Group=zerver
WorkingDirectory=/opt/zerver
ExecStart=/opt/zerver/zerver_example
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## Configuration

### Environment Variables
- `ZERVER_HOST`: Server bind address (default: 127.0.0.1)
- `ZERVER_PORT`: Server port (default: 8080)
- `ZERVER_DEBUG`: Enable debug mode (default: false)

### Configuration File
See `config.example.toml` for comprehensive configuration options.

## Monitoring

### Health Checks
Zerver applications respond to standard health check endpoints:
```bash
curl http://localhost:8080/health
```

### Metrics (Future)
- Prometheus metrics endpoint: `/metrics`
- OTLP trace export support

### Logs
- Structured JSON logs to stdout/stderr
- Configurable log levels
- Request tracing with correlation IDs

## Security Considerations

### Network Security
- Bind to localhost (127.0.0.1) for development
- Use reverse proxy (nginx, caddy) for production
- Configure firewalls appropriately

### Application Security
- Implement authentication middleware
- Validate input data
- Use HTTPS in production
- Configure CORS appropriately

### Process Security
- Run as non-root user
- Use process supervisors (systemd, supervisor)
- Configure resource limits

## Performance Tuning

### Build Optimizations
```bash
# Maximum optimization
zig build -Doptimize=ReleaseFast

# Size optimization
zig build -Doptimize=ReleaseSmall
```

### Runtime Configuration
- Adjust connection limits based on load
- Configure appropriate timeouts
- Monitor memory usage and GC pressure

## Troubleshooting

### Common Issues

1. **Port already in use**
   ```bash
   lsof -i :8080
   kill -9 <PID>
   ```

2. **Permission denied**
   ```bash
   # Run on privileged ports as root, or use port > 1024
   sudo ./zerver_example
   ```

3. **Build failures**
   ```bash
   # Clean and rebuild
   zig build clean
   zig build
   ```

### Debug Mode
```bash
# Enable debug logging
export ZERVER_DEBUG=true
./zerver_example
```

### Performance Profiling
```bash
# Use zig's built-in profiler
zig build -Doptimize=ReleaseFast --pgo
```

## Production Checklist

- [ ] Build with `ReleaseFast` optimization
- [ ] Configure appropriate log levels
- [ ] Set up process monitoring
- [ ] Configure reverse proxy
- [ ] Enable HTTPS
- [ ] Set up log aggregation
- [ ] Configure backups (if using databases)
- [ ] Set up monitoring and alerting
- [ ] Test under load
- [ ] Plan rollback strategy

## Support

For deployment issues:
1. Check application logs
2. Verify configuration
3. Test with minimal example
4. Check system resources
5. Review security settings