# Complete VPS Security Startup Guide: NFTables + Fail2Ban + ICMP Rate Limiting

## Quick Start Commands

### 1. Installation
```bash
# Ubuntu/Debian
sudo apt update && sudo apt install nftables fail2ban

# CentOS/RHEL/Rocky
sudo dnf install nftables fail2ban
```

### 2. Basic Setup (5-minute configuration)
```bash
# Copy default Fail2Ban config
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

# Create NFTables config
sudo nano /etc/nftables.conf
```

## Complete Step-by-Step Setup

### Phase 1: NFTables Configuration with ICMP Rate Limiting

#### 1.1 Create Main Configuration with ICMP Rate Limiting
```bash
sudo nano /etc/nftables.conf
```

```nft
#!/usr/sbin/nft -f

flush ruleset

define WAN_INTERFACE = eth0
define SSH_PORT = 22
define HTTP_PORT = 80
define HTTPS_PORT = 443

table inet filter {
    # ICMP rate limiting sets (IPv4 and IPv6)
    set icmp4_rate_limit {
        type ipv4_addr
        size 65535
        flags dynamic,timeout
        timeout 1m
    }

    set icmp6_rate_limit {
        type ipv6_addr
        size 65535
        flags dynamic,timeout
        timeout 1m
    }

    chain input {
        type filter hook input priority 0; policy drop;
        
        # Established connections
        ct state established,related accept
        
        # Loopback
        iifname "lo" accept
        
        # ICMPv4 rate limiting (ping)
        ip protocol icmp icmp type { echo-request, echo-reply } \
        limit rate over 1/second burst 5 packets drop
        
        # ICMPv6 rate limiting
        ip6 nexthdr icmpv6 icmpv6 type { echo-request, echo-reply } \
        add @icmp4_rate_limit { ip saddr } \
        limit rate 5/second burst 10 packets accept
        
        # IPv4 ping flood protection
        ip protocol icmp icmp type echo-request \
        limit rate 5/minute burst 5 packets accept
        
        # ICMPv6 rate limiting
        ip6 nexthdr icmpv6 icmpv6 type echo-request \
        add @icmp6_rate_limit { ip6 saddr } \
        limit rate 5/minute burst 5 packets accept
        
        # SSH access
        tcp dport $SSH_PORT accept
        
        # Web services
        tcp dport { $HTTP_PORT, $HTTPS_PORT } accept
        
        # Counter for monitoring
        counter drop
    }
    
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
```

#### 1.2 Enhanced ICMP Rate Limiting Configuration
For more granular control, use this advanced version:

```nft
#!/usr/sbin/nft -f

flush ruleset

define WAN_INTERFACE = eth0
define SSH_PORT = 22
define HTTP_PORT = 80
define HTTPS_PORT = 443

table inet filter {
    # Rate limiting sets
    set icmp_ping_limit {
        type ipv4_addr
        flags dynamic
        size 65535
        timeout 30s
    }

    set icmp6_ping_limit {
        type ipv6_addr
        flags dynamic
        size 65535
        timeout 30s
    }

    chain input {
        type filter hook input priority 0; policy drop;
        
        # Established/related connections
        ct state established,related accept
        
        # Loopback
        iifname "lo" accept
        
        # ===== ICMPv4 RATE LIMITING =====
        # Allow normal ping (1 per second)
        ip protocol icmp icmp type echo-request \
        limit rate 1/second burst 3 packets accept
        
        # ICMPv4 flood protection
        ip protocol icmp icmp type echo-request \
        add @icmp_ping_limit { ip saddr } \
        limit rate 5/minute burst 5 packets accept
        
        # Drop excessive ICMPv4
        ip protocol icmp icmp type echo-request \
        counter drop
        
        # Allow ICMPv4 replies
        ip protocol icmp icmp type echo-reply accept
        
        # Essential ICMPv4 types (unlimited)
        ip protocol icmp icmp type { destination-unreachable, time-exceeded } accept
        
        # ===== ICMPv6 RATE LIMITING =====
        # ICMPv6 echo requests (ping)
        ip6 nexthdr icmpv6 icmpv6 type echo-request \
        add @icmp6_ping_limit { ip6 saddr } \
        limit rate 5/minute burst 5 packets accept
        
        # Essential ICMPv6 types (unlimited)
        ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded } accept
        
        # SSH access
        tcp dport $SSH_PORT accept
        
        # Web services
        tcp dport { $HTTP_PORT, $HTTPS_PORT } accept
        
        # Counter for dropped packets
        counter drop
    }
    
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
```

#### 1.3 Test and Apply NFTables
```bash
# Test configuration syntax
sudo nft -f /etc/nftables.conf

# Verify rules are applied
sudo nft list ruleset

# Monitor ICMP rate limiting
sudo nft list set inet filter icmp_ping_limit
sudo nft list set inet filter icmp6_ping_limit

# Enable and start service
sudo systemctl enable nftables
sudo systemctl start nftables
```

### Phase 2: Fail2Ban Integration

#### 2.1 Configure Jails
```bash
sudo nano /etc/fail2ban/jail.local
```

```ini
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = auto

# SSH Protection
[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 3

# SSH DDoS Protection
[sshd-ddos]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 5
findtime = 600
bantime = 7200

# Web Server Protection
[nginx-http-auth]
enabled = true
port = http,https
logpath = /var/log/nginx/error.log

[apache-auth]
enabled = true
port = http,https
logpath = /var/log/apache2/*error.log

# WordPress Protection
[wordpress]
enabled = true
port = http,https
logpath = /var/log/nginx/access.log
filter = wordpress
```

#### 2.2 Create WordPress Filter
```bash
sudo nano /etc/fail2ban/filter.d/wordpress.conf
```

```ini
[Definition]
failregex = ^<HOST> -.*(wp-login\.php|xmlrpc\.php).* 404$
ignoreregex =
```

#### 2.3 Enable and Test Fail2Ban
```bash
# Enable Fail2Ban
sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# Test configuration
sudo fail2ban-client -t
```

### Phase 3: Advanced ICMP Configuration

#### 3.1 Comprehensive ICMP Rate Limiting
```bash
sudo nano /etc/nftables-icmp.conf
```

```nft
#!/usr/sbin/nft -f

# ICMP-specific table for advanced rate limiting
table inet icmp_filter {
    # Per-IP ping counters
    set ping_rates_v4 {
        type ipv4_addr
        flags dynamic
        timeout 30s
    }

    set ping_rates_v6 {
        type ipv6_addr
        flags dynamic
        timeout 30s
    }

    chain input {
        type filter hook input priority 10; policy accept;
        
        # ICMPv4: Allow 2 pings per second, max 10 per minute per IP
    }

    chain icmpv4_input {
        # Normal ping traffic (limited)
        ip protocol icmp icmp type echo-request \
        add @ping_rates_v4 { ip saddr timeout 30s } \
        limit rate over 2/second burst 4 packets drop
        
        # Essential ICMPv4 messages (unlimited)
        ip protocol icmp icmp type { destination-unreachable, source-quench, time-exceeded, parameter-problem } accept
        
        # ICMPv6: Essential types
        ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem } accept
        
        # ICMPv6 ping rate limiting
        ip6 nexthdr icmpv6 icmpv6 type echo-request \
        add @ping_rates_v6 { ip6 saddr timeout 30s } \
        limit rate over 2/second burst 4 packets drop
    }
}
```

#### 3.2 Integration with Main NFTables
Update your main configuration to include ICMP filtering:

```nft
#!/usr/sbin/nft -f

flush ruleset

define WAN_INTERFACE = eth0
define SSH_PORT = 22
define HTTP_PORT = 80
define HTTPS_PORT = 443

table inet filter {
    # ICMP rate limiting sets
    set icmp4_limits {
        type ipv4_addr
        flags dynamic,timeout
        timeout 1m
    }

    set icmp6_limits {
        type ipv6_addr
        flags dynamic,timeout
        timeout 1m
    }

    chain input {
        type filter hook input priority 0; policy drop;
        
        ct state established,related accept
        iifname "lo" accept
        
        # ===== ADVANCED ICMP RATE LIMITING =====
        
        # ICMPv4: Allow but rate limit
        ip protocol icmp icmp type echo-request \
        add @icmp4_limits { ip saddr } \
        limit rate 2/second burst 5 packets accept
        
        # ICMPv6: Allow but rate limit
        ip6 nexthdr icmpv6 icmpv6 type echo-request \
        add @icmp6_limits { ip6 saddr } \
        limit rate 2/second burst 5 packets accept
        
        # Drop excessive ICMP without logging
        ip protocol icmp icmp type echo-request drop
        ip6 nexthdr icmpv6 icmpv6 type echo-request drop
        
        # SSH access
        tcp dport $SSH_PORT accept
        
        # Web services
        tcp dport { $HTTP_PORT, $HTTPS_PORT } accept
        
        counter drop
    }
    
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    
    chain output {
        type filter hook output priority 0; policy accept;
    }
}

# Fail2Ban will automatically create this
table inet f2b-table {
    chain f2b-chain {
        # Fail2Ban adds rules here automatically
    }
}
```

## Management Commands Cheat Sheet

### NFTables ICMP Monitoring Commands
```bash
# View current ICMP rate limiting sets
sudo nft list set inet filter icmp4_limits
sudo nft list set inet filter icmp6_limits

# Monitor ICMP traffic
sudo nft list chain inet filter input | grep icmp

# Check ICMP drop counters
sudo nft list ruleset | grep -A2 -B2 "counter drop"

# Real-time ICMP monitoring
sudo watch -n 1 'nft list set inet filter icmp4_limits; nft list set inet filter icmp6_limits
```

### Fail2Ban Commands
```bash
# View status
sudo fail2ban-client status
sudo fail2ban-client status sshd

# Test ICMP rate limiting
ping -c 10 your-vps-ip

# View ICMP statistics
sudo nft list ruleset | grep -E "(icmp|counter)" | grep -v "established"
```

## Complete Management Script with ICMP Controls

```bash
#!/bin/bash
# /usr/local/bin/vps-security

case "$1" in
    start)
        echo "Starting security services..."
        sudo systemctl start nftables
        sudo systemctl start fail2ban
        ;;
    stop)
        echo "Stopping security services..."
        sudo systemctl stop fail2ban
        sudo systemctl stop nftables
        ;;
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    status)
        echo "=== NFTables Status ==="
        sudo nft list ruleset | head -20
        echo -e "\n=== Fail2Ban Status ==="
        sudo fail2ban-client status
        ;;
    reload)
        echo "Reloading configurations..."
        sudo nft -f /etc/nftables.conf
        sudo fail2ban-client reload
        ;;
    icmp-status)
        echo "=== ICMP Rate Limiting Status ==="
        echo "ICMPv4 Limits:"
        sudo nft list set inet filter icmp4_limits 2>/dev/null || echo "No ICMPv4 limits set"
        echo -e "\nICMPv6 Limits:"
        sudo nft list set inet filter icmp6_limits 2>/dev/null || echo "No ICMPv6 limits set"
        ;;
    banlist)
        echo "=== Currently Banned IPs ==="
        sudo fail2ban-client status sshd | grep -A 100 "Banned IP list"
        ;;
    unban)
        if [ -z "$2" ]; then
            echo "Usage: $0 unban <IP>"
            exit 1
        fi
        sudo fail2ban-client set sshd unbanip $2
        echo "Unbanned IP: $2"
        ;;
    test-icmp)
        echo "Testing ICMP rate limiting..."
        echo "Send 10 rapid pings:"
        ping -c 10 your-vps-ip
        ;;
    clear-icmp)
        echo "Clearing ICMP rate limits..."
        sudo nft flush set inet filter icmp4_limits
        sudo nft flush set inet filter icmp6_limits
        echo "ICMP rate limits cleared"
        ;;
    test)
        # Test if services are responsive
        sudo nft list ruleset > /dev/null && echo "✓ NFTables OK" || echo "✗ NFTables Error"
        sudo fail2ban-client status > /dev/null && echo "✓ Fail2Ban OK" || echo "✗ Fail2Ban Error"
        ;;
    logs)
        echo "=== Fail2Ban Logs ==="
        sudo tail -f /var/log/fail2ban.log
        ;;
    *)
        echo "VPS Security Manager"
        echo "Usage: $0 {start|stop|restart|status|icmp-status|reload|banlist|unban <IP>|test-icmp|clear-icmp|test|logs}"
        echo ""
        echo "Examples:"
        echo "  $0 start        - Start all services"
        echo "  $0 icmp-status - Show ICMP rate limiting"
        echo "  $0 test-icmp   - Test ICMP rate limiting"
        echo "  $0 clear-icmp  - Clear ICMP rate limits"
        echo "  $0 unban 192.168.1.100"
        ;;
esac
```

**Make it executable:**
```bash
sudo chmod +x /usr/local/bin/vps-security
```

## Testing Your Setup

### 1. ICMP Rate Limiting Test
```bash
# Test normal ping (should work)
ping -c 3 your-vps-ip

# Test rapid ping (should be limited)
ping -c 20 -i 0.1 your-vps-ip

# Monitor ICMP drops in real-time
sudo watch -n 1 'nft list ruleset | grep -E "(icmp|drop)"'

# Verify ICMP rate limiting sets
sudo nft list set inet filter icmp4_limits
sudo nft list set inet filter icmp6_limits
```

### 2. Emergency Recovery (If Locked Out)
```bash
# Use VPS console access, then:
sudo systemctl stop fail2ban
sudo nft flush ruleset
sudo nft add rule inet filter input ct state established,related accept
sudo nft add rule inet filter input iifname "lo" accept
sudo nft add rule inet filter input tcp dport 22 accept
```

## Monitoring and Maintenance

### ICMP-Specific Health Checks
```bash
# Add to crontab (crontab -e)
# Daily ICMP rate limiting check
0 2 * * * /usr/local/bin/vps-security icmp-status
```

### Log Monitoring with ICMP Focus
```bash
# Monitor ICMP traffic
sudo tcpdump -i eth0 icmp or icmp6

# Monitor ICMP drops
sudo watch -n 1 'nft list ruleset | grep "counter drop"'
```

## Quick Reference

**ICMP Rate Limiting Status:**
```bash
sudo nft list set inet filter icmp4_limits
sudo nft list set inet filter icmp6_limits
```

**Test ICMP Flood Protection:**
```bash
# From another machine, test rapid pings
ping -f your-vps-ip

# Monitor results
sudo nft list ruleset | grep -B2 -A2 "icmp"
```

**Common ICMP Issues:**
- **Too restrictive?** Increase rate limits: `limit rate 5/second burst 10 packets`
- **Not limiting enough?** Decrease rates: `limit rate 1/second burst 3 packets`
- **IPv6 not working?** Check if `icmp6_limits` set is populated

---

**Time to Complete:** ~15 minutes for basic setup, ~25 minutes for advanced configuration

**Security Level:** Enterprise-grade protection against ICMP floods and brute force attacks

**Next Steps:** Monitor ICMP traffic patterns and adjust rate limits accordingly
