"""Dune Dashboard Diagnostic Script

Tests connectivity to all critical services:
- SSH to game server VM
- Database port-forward
- Director port-forward
- BGD pod status and logs
- RabbitMQ pods
- Kubernetes namespace access

Usage:
    python scripts/diagnostic.py [settings.yaml]
"""

import sys
import os
import subprocess
import json

try:
    import yaml
except ImportError:
    print("[ERROR] PyYAML not installed. Run: pip install pyyaml")
    sys.exit(1)


def load_settings(path):
    with open(path) as f:
        return yaml.safe_load(f)


def run_cmd(cmd, timeout=15):
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return result.returncode, result.stdout.strip(), result.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "Command timed out"
    except Exception as e:
        return -1, "", str(e)


def check_ssh(settings):
    print("\n[1/6] Checking SSH connection...")
    host = settings['server']['host']
    ssh_key = os.path.expandvars(settings['server'].get('ssh_key', ''))
    ssh_user = settings['server'].get('ssh_user', 'dune')

    rc, out, err = run_cmd(
        f'ssh -i "{ssh_key}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes {ssh_user}@{host} "echo OK"',
        timeout=15
    )
    if rc == 0 and 'OK' in out:
        print("  [OK] SSH connection successful")
        return True
    else:
        print(f"  [FAIL] SSH failed: {err or out}")
        return False


def check_namespace(settings):
    print("\n[2/6] Checking Kubernetes namespace...")
    ns = settings.get('kubernetes', {}).get('namespace', '')
    if not ns:
        print("  [FAIL] Kubernetes namespace not set in settings.yaml")
        return False

    host = settings['server']['host']
    ssh_key = os.path.expandvars(settings['server'].get('ssh_key', ''))
    ssh_user = settings['server'].get('ssh_user', 'dune')

    rc, out, err = run_cmd(
        f'ssh -i "{ssh_key}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 {ssh_user}@{host} "sudo kubectl get namespace {ns}"',
        timeout=15
    )
    if rc == 0 and ns in out:
        print(f"  [OK] Namespace '{ns}' exists")
        return True
    else:
        print(f"  [FAIL] Namespace '{ns}' not found: {err or out}")
        return False


def check_db_port_forward(settings):
    print("\n[3/6] Checking database port-forward...")
    port = settings.get('server', {}).get('port', 15432)

    import socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(3)
    try:
        sock.connect(('127.0.0.1', port))
        sock.close()
        print(f"  [OK] Database port-forward listening on localhost:{port}")
        return True
    except Exception:
        print("")
        print("+----------------------------------------------------------+")
        print("|  [FAIL] Database port-forward not connected               |")
        print("|                                                          |")
        print("|  *** THIS IS NOT CRITICAL ***                            |")
        print("|  The database port-forward requires the launcher to be   |")
        print("|  running. If you're just running diagnostics standalone,  |")
        print("|  this will fail. Start the launcher first - it sets up    |")
        print("|  the SSH tunnel and port-forwards automatically.         |")
        print("+----------------------------------------------------------+")
        print("")
        return False


def check_director_port_forward(settings):
    print("\n[4/6] Checking director port-forward...")
    port = settings.get('director', {}).get('port', 32479)

    import socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(3)
    try:
        sock.connect(('127.0.0.1', port))
        sock.close()
        print(f"  [OK] Director port-forward listening on localhost:{port}")

        import urllib.request
        try:
            r = urllib.request.urlopen(f'http://127.0.0.1:{port}/v0/battlegroup', timeout=5)
            data = json.loads(r.read())
            print(f"  [OK] Director API responding (battlegroup loaded)")
            return True
        except Exception as e:
            print(f"  [WARN] Director port open but API not responding: {e}")
            print("         The BGD pod may be starting or have internal errors")
            return False
    except Exception:
        print(f"  [FAIL] Cannot connect to localhost:{port}")
        print("         NOTE: This is expected if the launcher hasn't started yet.")
        print("         Run the launcher and these will connect automatically.")
        return False


def check_bgd_pod(settings):
    print("\n[5/6] Checking BGD pod status...")
    host = settings['server']['host']
    ssh_key = os.path.expandvars(settings['server'].get('ssh_key', ''))
    ssh_user = settings['server'].get('ssh_user', 'dune')
    ns = settings.get('kubernetes', {}).get('namespace', '')

    rc, out, err = run_cmd(
        f'ssh -i "{ssh_key}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 {ssh_user}@{host} "sudo kubectl get pods -n {ns} | grep bgd"',
        timeout=15
    )
    if not out:
        print("  [FAIL] No BGD pod found")
        print("         The battlegroup director deployment may be scaled to 0")
        return False

    for line in out.split('\n'):
        parts = line.split()
        if len(parts) >= 3:
            name = parts[0]
            ready = parts[1]
            status = parts[2]
            if 'Running' in status and '1/1' in ready:
                print(f"  [OK] BGD pod running: {name} (ready={ready})")
            else:
                print(f"  [WARN] BGD pod issue: {name} (ready={ready}, status={status})")

    if 'CrashLoopBackOff' in out:
        print("\n  BGD pod is crash looping. Checking recent logs:")
        rc, logs, _ = run_cmd(
            f'ssh -i "{ssh_key}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 {ssh_user}@{host} "sudo kubectl logs -n {ns} -l app={ns}-bgd-deploy --tail=20"',
            timeout=30
        )
        if logs:
            for line in logs.split('\n')[-10:]:
                print(f"    {line}")

    return 'Running' in out


def check_rabbitmq(settings):
    print("\n[6/6] Checking RabbitMQ pods...")
    host = settings['server']['host']
    ssh_key = os.path.expandvars(settings['server'].get('ssh_key', ''))
    ssh_user = settings['server'].get('ssh_user', 'dune')
    ns = settings.get('kubernetes', {}).get('namespace', '')

    rc, out, err = run_cmd(
        f'ssh -i "{ssh_key}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 {ssh_user}@{host} "sudo kubectl get pods -n {ns} | grep mq"',
        timeout=15
    )
    if not out:
        print("  [FAIL] No RabbitMQ pods found")
        return False

    all_ok = True
    for line in out.split('\n'):
        parts = line.split()
        if len(parts) >= 3:
            name = parts[0]
            ready = parts[1]
            status = parts[2]
            if 'Running' in status:
                print(f"  [OK] RabbitMQ running: {name} (ready={ready})")
            else:
                print(f"  [WARN] RabbitMQ issue: {name} (ready={ready}, status={status})")
                all_ok = False

    return all_ok


def main():
    settings_path = sys.argv[1] if len(sys.argv) > 1 else 'settings.yaml'
    if not os.path.exists(settings_path):
        print(f"[ERROR] Settings file not found: {settings_path}")
        sys.exit(1)

    print("=" * 60)
    print("  Dune Awakening Dashboard - Diagnostic Tool")
    print("=" * 60)

    settings = load_settings(settings_path)

    results = []
    results.append(("SSH Connection", check_ssh(settings)))
    results.append(("Kubernetes Namespace", check_namespace(settings)))
    results.append(("Database Port-Forward", check_db_port_forward(settings)))
    results.append(("Director Port-Forward", check_director_port_forward(settings)))
    results.append(("BGD Pod", check_bgd_pod(settings)))
    results.append(("RabbitMQ", check_rabbitmq(settings)))

    print("\n" + "=" * 60)
    print("  Summary")
    print("=" * 60)

    passed = sum(1 for _, ok in results if ok)
    total = len(results)

    for name, ok in results:
        status = "[OK]" if ok else "[FAIL]"
        print(f"  {status} {name}")

    print(f"\n  {passed}/{total} checks passed")

    if passed < total:
        print("\n  Troubleshooting tips:")
        print("  - Restart the launcher to re-establish port-forwards")
        print("  - Check BGD logs: sudo kubectl logs -n <ns> -l app=<ns>-bgd-deploy --tail=50")
        print("  - If RabbitMQ auth fails, try restarting the full battlegroup")
        print("  - Run the launcher with verbose output for more details")

    sys.exit(0 if passed == total else 1)


if __name__ == '__main__':
    main()
