"""Testes do volunteer-service. boto3 só conecta no DynamoDB ao chamar put_item/scan,
então health e validação de payload rodam sem AWS."""
import pytest

from app import app


@pytest.fixture
def client():
    app.config["TESTING"] = True
    return app.test_client()


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.get_json() == {"status": "ok", "service": "volunteer-service"}


def test_register_missing_fields_returns_400(client):
    r = client.post("/volunteers", json={"name": "Sem email"})
    assert r.status_code == 400
