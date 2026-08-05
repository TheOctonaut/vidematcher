from redis import Redis
from rq import Queue

from app.config import settings


redis_conn = Redis.from_url(settings.redis_url)
queue = Queue("vidematcher", connection=redis_conn, default_timeout=settings.run_timeout_seconds)
