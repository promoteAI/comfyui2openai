from __future__ import annotations

import asyncio
import logging
import shutil
from pathlib import Path
from typing import TYPE_CHECKING

from .util import utc_now_unix

if TYPE_CHECKING:
    from .jobs import Job, JobManager


logger = logging.getLogger(__name__)

TERMINAL_JOB_STATUSES = {"completed", "failed", "cancelled"}


def _is_terminal(job: "Job") -> bool:
    return str(getattr(job, "status", "") or "").lower() in TERMINAL_JOB_STATUSES


async def prune_jobs(
    manager: "JobManager",
    *,
    ttl_seconds: int,
    max_jobs: int,
) -> list[str]:
    ttl_seconds = max(0, int(ttl_seconds))
    max_jobs = max(0, int(max_jobs))

    cutoff = utc_now_unix() - ttl_seconds if ttl_seconds > 0 else None
    removed_job_ids: list[str] = []
    removed_run_dirs: list[Path] = []

    async with manager._lock:
        jobs = list(manager._jobs.values())
        job_sort_key = {job.job_id: (int(job.created_at or 0), job.job_id) for job in jobs}
        removable_ids: set[str] = set()

        if cutoff is not None:
            for job in jobs:
                if _is_terminal(job) and int(job.created_at or 0) <= cutoff:
                    removable_ids.add(job.job_id)

        remaining_jobs = [job for job in jobs if job.job_id not in removable_ids]
        if max_jobs > 0 and len(remaining_jobs) > max_jobs:
            overflow = len(remaining_jobs) - max_jobs
            terminal_jobs = sorted(
                (job for job in remaining_jobs if _is_terminal(job)),
                key=lambda job: (int(job.created_at or 0), job.job_id),
            )
            for job in terminal_jobs[:overflow]:
                removable_ids.add(job.job_id)

        removed_job_ids = sorted(removable_ids, key=lambda job_id: job_sort_key.get(job_id, (0, job_id)))
        for job_id in removed_job_ids:
            manager._jobs.pop(job_id, None)
            removed_run_dirs.append((manager.cfg.runs_dir / job_id).resolve())

    if removed_job_ids:
        async with manager._sub_lock:
            for job_id in removed_job_ids:
                manager._subscribers.pop(job_id, None)

        for run_dir in removed_run_dirs:
            try:
                shutil.rmtree(run_dir, ignore_errors=True)
            except Exception:
                logger.exception("job run directory cleanup failed: path=%s", run_dir)

    return removed_job_ids


async def run_job_retention_forever(
    manager: "JobManager",
    *,
    interval_s: float,
    ttl_seconds: int,
    max_jobs: int,
) -> None:
    interval_s = float(interval_s)
    if interval_s <= 0:
        raise ValueError("interval_s must be > 0")

    while True:
        await asyncio.sleep(interval_s)
        removed_job_ids = await prune_jobs(manager, ttl_seconds=ttl_seconds, max_jobs=max_jobs)
        if removed_job_ids:
            logger.info(
                "pruned jobs from memory: count=%s ttl_seconds=%s max_jobs=%s job_ids=%s",
                len(removed_job_ids),
                ttl_seconds,
                max_jobs,
                removed_job_ids,
            )
