from locust import HttpUser, task, between
import time

class MicroserviceUser(HttpUser):
    wait_time = between(1, 2)

    @task
    def call_service_chain(self):
        start = time.time()

        with self.client.get("/", catch_response=True) as response:
            latency = (time.time() - start) * 1000  # ms

            if response.status_code != 200:
                response.failure(f"Error {response.status_code}")
            else:
                response.success()
                print(f"Latency: {latency:.2f} ms")
