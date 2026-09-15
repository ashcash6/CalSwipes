from alembic import context
from app.config import Settings
from app.db import Base, make_engine

config = context.config
if context.is_offline_mode():
    context.configure(url=Settings.from_env().database_url, target_metadata=Base.metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()
else:
    engine = make_engine(Settings.from_env().database_url)
    with engine.connect() as connection:
        context.configure(connection=connection, target_metadata=Base.metadata)
        with context.begin_transaction():
            context.run_migrations()
    engine.dispose()
