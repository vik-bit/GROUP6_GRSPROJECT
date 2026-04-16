#!/usr/bin/env python3
"""
VM-tailored headless Locust runner.

Behavior:
 - uses a warm-up period to let pods come up (so initial 503s aren't recorded)
 - after warm-up, enables CSV export via StatsCSVFileWriter
 - parameters controlled via environment variables

Example:
  TARGET_HOST=http://vm1-control:80 USERS=30 SPAWN_RATE=5 RUN_TIME=180 WARM_UP=30 CSV_BASE=locust_stats python run_locust_headless-vm.py
"""

import os
import gevent
from locust.env import Environment
from locust.stats import StatsCSVFileWriter
from locust import events

# import VM-specific locustfile
#from locustfile_vm import MicroserviceUser  # placeholder import override below


def _env_int(name, default):
    try:
        return int(os.getenv(name, default))
    except Exception:
        return int(default)


def main():
    USERS = _env_int("USERS", 20)
    SPAWN_RATE = _env_int("SPAWN_RATE", 5)
    RUN_TIME = _env_int("RUN_TIME", 120)  # seconds
    WARM_UP = _env_int("WARM_UP", 20)  # seconds
    CSV_BASE = os.getenv("CSV_BASE", "locust_stats")

    target_host = os.getenv("TARGET_HOST")

    # Try to import the VM-specific locustfile dynamically (file: locustfile-vm.py)
    # This avoids name collisions with the default locustfile.py
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("locustfile_vm", os.path.join(os.path.dirname(__file__), "locustfile-vm.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        UserClass = getattr(mod, "MicroserviceUser")
    except Exception:
        # fallback: try importing default MicroserviceUser
        from locustfile import MicroserviceUser as UserClass

    env = Environment(user_classes=[UserClass])
    if target_host:
        env.host = target_host
    else:
       env.host = "http://10.97.249.201"

    runner = env.create_local_runner()

    print(f"Starting runner: users={USERS} spawn_rate={SPAWN_RATE}")
    runner.start(USERS, spawn_rate=SPAWN_RATE)

    print(f"Warming up for {WARM_UP} seconds (not recording CSV)...")
    gevent.sleep(WARM_UP)

    print("Starting CSV writers...")
    csv_writer = StatsCSVFileWriter(environment=env, filename_prefix=CSV_BASE)

    test_phase = max(0, RUN_TIME - WARM_UP)
    print(f"Running test phase for {test_phase} seconds...")
    if test_phase > 0:
        gevent.sleep(test_phase)

    print("Stopping runner and closing CSV writer...")
    runner.quit()
    try:
        csv_writer.close()
    except Exception:
        pass

    events.quitting.fire()
    print("Done. CSV files written with base:", CSV_BASE)


if __name__ == "__main__":
    main()
