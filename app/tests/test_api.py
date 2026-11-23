from __future__ import annotations

from fastapi.testclient import TestClient


def test_healthz_does_not_need_the_database(client: TestClient) -> None:
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readyz_checks_the_database(client: TestClient) -> None:
    response = client.get("/readyz")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_info_reports_version_and_env(client: TestClient) -> None:
    body = client.get("/api/info").json()
    assert body["app"] == "taskapi"
    assert body["env"] == "test"
    assert body["version"]
    assert body["pod"]


def test_task_lifecycle(client: TestClient) -> None:
    created = client.post("/api/tasks", json={"title": "  Deploy with Argo CD  "})
    assert created.status_code == 201
    task = created.json()
    assert task["title"] == "Deploy with Argo CD"
    assert task["done"] is False

    listed = client.get("/api/tasks").json()
    assert [t["id"] for t in listed] == [task["id"]]

    patched = client.patch(f"/api/tasks/{task['id']}", json={"done": True})
    assert patched.status_code == 200
    assert patched.json()["done"] is True

    assert client.get(f"/api/tasks/{task['id']}").json()["done"] is True

    deleted = client.delete(f"/api/tasks/{task['id']}")
    assert deleted.status_code == 204
    assert client.get(f"/api/tasks/{task['id']}").status_code == 404


def test_list_is_newest_first_and_limited(client: TestClient) -> None:
    for i in range(3):
        client.post("/api/tasks", json={"title": f"task {i}"})
    titles = [t["title"] for t in client.get("/api/tasks?limit=2").json()]
    assert titles == ["task 2", "task 1"]


def test_validation_errors(client: TestClient) -> None:
    assert client.post("/api/tasks", json={"title": ""}).status_code == 422
    assert client.post("/api/tasks", json={"title": "x" * 201}).status_code == 422
    assert client.get("/api/tasks?limit=0").status_code == 422
    assert client.get("/api/tasks/not-a-number").status_code == 422


def test_unknown_task_returns_404(client: TestClient) -> None:
    assert client.get("/api/tasks/999999").status_code == 404
    assert client.patch("/api/tasks/999999", json={"done": True}).status_code == 404
    assert client.delete("/api/tasks/999999").status_code == 404


def test_metrics_use_route_templates_not_raw_paths(client: TestClient) -> None:
    from prometheus_client import REGISTRY

    client.get("/api/tasks/424242")
    routes = {
        sample.labels.get("route")
        for metric in REGISTRY.collect()
        if metric.name == "http_requests"
        for sample in metric.samples
    }
    assert "/api/tasks/{task_id}" in routes
    assert "/api/tasks/424242" not in routes
