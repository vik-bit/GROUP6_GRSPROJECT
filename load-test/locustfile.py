from locust import HttpUser, task, between

class MicroserviceUser(HttpUser):
    host = "http://localhost:8080"
    wait_time = between(1, 2)

    @task
    def call_service_chain(self):
        self.client.get("/")
