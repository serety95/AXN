# fastapi-patterns — Extended Reference

## Testing with httpx and pytest

```python
# tests/conftest.py
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.database import Base
from app.dependencies import get_db
from app.main import create_app

TEST_DATABASE_URL = "sqlite+aiosqlite:///:memory:"

engine = create_async_engine(TEST_DATABASE_URL)
TestingSessionLocal = async_sessionmaker(engine, expire_on_commit=False)


@pytest_asyncio.fixture(autouse=True)
async def setup_db():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)


@pytest_asyncio.fixture
async def db_session():
    async with TestingSessionLocal() as session:
        yield session
        await session.rollback()


@pytest_asyncio.fixture
async def client(db_session: AsyncSession):
    app = create_app()

    async def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db

    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as ac:
        yield ac


@pytest_asyncio.fixture
async def registered_user(client: AsyncClient) -> dict:
    resp = await client.post("/users/", json={
        "email": "test@example.com",
        "username": "testuser",
        "password": "securepass1",
        "password_confirm": "securepass1",
    })
    assert resp.status_code == 201
    return resp.json()


@pytest_asyncio.fixture
async def auth_token(client: AsyncClient, registered_user: dict) -> str:
    resp = await client.post("/users/token", data={
        "username": "test@example.com",
        "password": "securepass1",
    })
    assert resp.status_code == 200
    return resp.json()["access_token"]


@pytest_asyncio.fixture
async def auth_client(client: AsyncClient, auth_token: str) -> AsyncClient:
    client.headers.update({"Authorization": f"Bearer {auth_token}"})
    return client
```

---

## Anti-Patterns

```python
# Bad: business logic inside route handlers.
@router.post("/users/")
async def create_user(payload: UserCreate, db: DbDep):
    hashed = bcrypt.hash(payload.password)
    user = User(email=payload.email, hashed_password=hashed)
    db.add(user)
    await db.commit()
    return user

# Good: thin route, transactional service handling.
@router.post("/users/", response_model=UserResponse, status_code=201)
async def create_user(payload: UserCreate, db: DbDep):
    try:
        return await UserService(db).create(payload)
    except DuplicateUserError:
        raise HTTPException(status_code=400, detail="Email already registered")


# Bad: sync DB calls in async routes block the event loop.
@router.get("/items/")
async def list_items(db: Session = Depends(get_db)):
    return db.query(Item).all()

# Good: use async SQLAlchemy executions.
@router.get("/items/")
async def list_items(db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Item))
    return result.scalars().all()
```

---

## Best Practices

- Always declare a typed `response_model` to prevent accidental PII/data leaks and output clean OpenAPI schemas.
- Consolidate standard middleware dependency injections via type-aliasing: `DbDep = Annotated[AsyncSession, Depends(get_db)]`.
- Wrap database mutation boundaries gracefully within transactions inside your service layer, catching structural database errors directly.
- Parse JWT parameters defensively, expecting potential string/integer cast mismatches from modern payload variations.
- Enforce deterministic sorting (e.g., `.order_by(Model.id)`) on all offset/limit paginated endpoints to avoid data skips.
- Isolate authorization checks from core authentication dependencies to provide precise REST status signals (`401` vs `403`).
