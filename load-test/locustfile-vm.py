import os
import time
from locust import HttpUser, task, between

# Configurable via environment variables for VM deployments
TARGET_ENDPOINT = os.getenv("TARGET_ENDPOINT", "/")
MAX_RETRIES = int(os.getenv("MAX_RETRIES", "3"))
REQUEST_TIMEOUT = int(os.getenv("REQUEST_TIMEOUT", "10"))


class MicroserviceUser(HttpUser):
    # Keep wait times conservative for resource-limited VMs
    wait_time = between(1, 3)

    @task
    def call_service_chain(self):
        # Retry on transient errors with small exponential backoff
        for attempt in range(MAX_RETRIES):
            start = time.time()
            try:
                with self.client.get(TARGET_ENDPOINT, catch_response=True, timeout=REQUEST_TIMEOUT) as response:
                    latency = (time.time() - start) * 1000  # ms

                    if response.status_code == 200:
                        response.success()
                        # Minimal logging to avoid flooding console on VMs
                        if os.getenv("VERBOSE", "0") == "1":
                            print(f"Latency: {latency:.2f} ms")
                        break
                    else:
                        # On non-200, retry up to MAX_RETRIES
                        if attempt < MAX_RETRIES - 1:
                            backoff = 0.5 * (2 ** attempt)
                            time.sleep(backoff)
                            continue
                        else:
                            response.failure(f"HTTP {response.status_code}")
            except Exception as e:
                # Connection errors/timeouts: retry a few times then mark failure
                if attempt < MAX_RETRIES - 1:
                    time.sleep(0.5 * (2 ** attempt))
                    continue
                # Last attempt: record minimal info
                if os.getenv("VERBOSE", "0") == "1":
                    print(f"Request error: {e}")
                break
