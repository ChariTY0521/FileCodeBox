from tortoise import connections


async def migrate():
    conn = connections.get("default")
    result = await conn.execute_query("PRAGMA table_info(filecodes)")
    columns = result[1] if result and len(result) > 1 else []

    column_names = [col[1] for col in columns]
    if "storage_type" in column_names:
        return

    await conn.execute_script(
        "ALTER TABLE filecodes ADD COLUMN storage_type VARCHAR(20) DEFAULT 'local'"
    )