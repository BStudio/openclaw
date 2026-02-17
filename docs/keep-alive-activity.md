# Activity-Based Keep-Alive Monitor

## Overview

Smart session keep-alive that monitors agent activity and only closes after 5 minutes of idle time.

## How It Works

### Activity Detection

The monitor checks for activity every 10 seconds across multiple signals:

1. **HTTP Connections** - Active connections to gateway (port 9339)
2. **CPU Usage** - Gateway process CPU >1% indicates processing
3. **Log Activity** - Recent log file modifications (<30s ago)
4. **Child Processes** - Active tool executions or subprocess activity
5. **Gateway Health** - Process existence check

### Behavior

**While Active:**

- ✅ Monitor stays running
- 🔍 Checks activity every 10 seconds
- 📊 Reports detected activity signals

**When Idle:**

- 💤 Starts 5-minute countdown
- ⏱️ Shows remaining idle time
- 🔄 Resets if activity resumes

**After 5 Minutes Idle:**

- ✨ Gracefully exits
- 📊 Reports total session time
- 👋 Allows session to close naturally

## Usage

### Start Monitor

```bash
nohup bash scripts/keep-alive-activity.sh > /tmp/keep-alive-activity.log 2>&1 &
```

### Check Status

```bash
# View live activity
tail -f /tmp/keep-alive-activity.log

# Check if running
ps aux | grep keep-alive-activity
```

### Stop Monitor

```bash
pkill -f "keep-alive-activity.sh"
```

## Configuration

Edit `scripts/keep-alive-activity.sh` to adjust:

- `IDLE_TIMEOUT=300` - Idle timeout in seconds (default: 5 minutes)
- `CHECK_INTERVAL=10` - Check frequency in seconds (default: 10s)

## Activity Indicators

The monitor reports different types of activity:

- 🌐 **Active connections** - HTTP requests in progress
- ⚡ **Gateway CPU** - Processing load percentage
- 📝 **Recent log activity** - Log writes within 30s
- 🔧 **Active child processes** - Tool executions
- ✅ **Gateway active** - Summary status

## Idle Detection

Monitor enters idle state when ALL conditions are true:

- No active HTTP connections
- Gateway CPU usage ≤1%
- No log modifications in last 30s
- No child processes
- Gateway process still running

## Advantages Over Timer-Based

### Old Timer Approach ❌

- Fixed 30-minute duration
- Closes even if work in progress
- Requires manual extension
- Wastes resources if work finishes early

### New Activity Approach ✅

- Adapts to actual work duration
- Never interrupts active work
- Automatic idle detection
- Closes promptly when done
- No manual timer management

## Example Output

```
[keep-alive] 🚀 Activity-based monitor started at Sun Feb 15 02:57:11 UTC 2026
[keep-alive] 💤 Will exit after 300s of idle time
[keep-alive] 🔍 Checking every 10s

[keep-alive] ⚡ Gateway CPU: 10%
[keep-alive] ✅ Gateway active (PID: 402) | 02:57:11

[keep-alive] 🌐 Active connections: 2
[keep-alive] ⚡ Gateway CPU: 8%
[keep-alive] ✅ Gateway active (PID: 402) | 02:57:21

[keep-alive] 💤 No activity detected - starting idle countdown

[keep-alive] 💤 Idle: 10s / 300s (290s remaining) | 02:58:45

[keep-alive] 🎯 Activity resumed! Resetting idle timer
[keep-alive] ⚡ Gateway CPU: 5%
[keep-alive] ✅ Gateway active (PID: 402) | 02:59:05
```

## Integration

### SessionStart Hook

```bash
# In ~/.openclaw/hooks/SessionStart:start
nohup bash scripts/keep-alive-activity.sh > /tmp/keep-alive-activity.log 2>&1 &
echo "Activity monitor started"
```

### Manual Start

```bash
# Start when you begin work
./scripts/keep-alive-activity.sh &

# Session stays alive until:
# - All work completes
# - 5 minutes pass with no activity
# - Monitor detects idle state
```

## Monitoring

### Check Current State

```bash
# Last 10 lines
tail -10 /tmp/keep-alive-activity.log

# Watch live
tail -f /tmp/keep-alive-activity.log

# Check if idle
tail -1 /tmp/keep-alive-activity.log | grep -q "💤" && echo "Idle" || echo "Active"
```

### Activity Stats

```bash
# Total connections
ss -tn state established '( dport = :9339 or sport = :9339 )' | wc -l

# Gateway CPU
ps aux | grep openclaw-gateway | grep -v grep | awk '{print $3}'

# Recent log changes
stat -c %Y /tmp/openclaw-gateway.log
```

## Troubleshooting

### Monitor exits immediately

- Check gateway is running: `pgrep -f openclaw-gateway`
- Verify gateway port: `ss -tln | grep 9339`

### False idle detection

- Increase CPU threshold in detect_activity()
- Reduce CHECK_INTERVAL for more frequent checks
- Add custom activity signals

### Session closes too soon

- Increase IDLE_TIMEOUT (default: 300s)
- Check activity detection is working correctly
- Review log for activity signals

## Migration from Timer-Based

1. Stop old monitors: `pkill -f "keep-alive-monitor.sh"`
2. Start new monitor: `nohup bash scripts/keep-alive-activity.sh > /tmp/keep-alive-activity.log 2>&1 &`
3. Verify: `tail -f /tmp/keep-alive-activity.log`

No more manual timer extensions needed! 🎉
