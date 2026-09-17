"""Testes do ngo-service. O pool de conexões é criado no import, então os testes
precisam de um Postgres acessível em DATABASE_URL (service container no CI)."""
import pytest

from app import app


@pytest.fixture
def client():
    app.config["TESTING"] = True
    return app.test_client()


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.get_json() == {"status": "ok", "service": "ngo-service"}


def test_create_ngo_missing_fields_returns_400(client):
    r = client.post("/ngos", json={"name": "Só nome"})
    assert r.status_code == 400
    assert "error" in r.get_json()


def test_create_and_list_ngo(client):
    payload = {"name": "ONG Teste", "email": "teste@ong.org", "cause": "Educação", "city": "SP"}
    r = client.post("/ngos", json=payload)
    assert r.status_code == 201
    assert r.get_json()["email"] == payload["email"]
    r = client.get("/ngos")
    assert r.status_code == 200
    assert any(n["email"] == payload["email"] for n in r.get_json())


def test_duplicate_email_returns_409(client):
    payload = {"name": "Dup", "email": "dup@ong.org", "cause": "Fome", "city": "RJ"}
    client.post("/ngos", json=payload)
    r = client.post("/ngos", json=payload)
    assert r.status_code == 409
