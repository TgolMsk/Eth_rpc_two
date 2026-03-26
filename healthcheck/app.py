"""
Ethereum RPC Health Check & Metrics Service

Exposes /health for load-balancer probes and /metrics for Prometheus scraping.
"""

import asyncio
import os
import time
from contextlib import asynccontextmanager
from enum import Enum

import httpx
from fastapi import FastAPI, Response
from prometheus_client import (
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

GETH_RPC_URL = os.getenv("GETH_RPC_URL", "http://geth:8545")
LIGHTHOUSE_API_URL = os.getenv("LIGHTHOUSE_API_URL", "http://lighthouse:5052")
CHECK_INTERVAL = int(os.getenv("CHECK_INTERVAL", "15"))

registry = CollectorRegistry()

block_number_gauge = Gauge(
    "eth_block_number", "Latest block number from execution client", registry=registry
)
peer_count_gauge = Gauge(
    "eth_peer_count", "Number of connected peers", registry=registry
)
sync_status_gauge = Gauge(
    "eth_syncing", "1 if node is syncing, 0 if fully synced", registry=registry
)
cl_sync_distance_gauge = Gauge(
    "cl_sync_distance", "Consensus layer sync distance (slots behind head)", registry=registry
)
health_check_counter = Counter(
    "eth_health_checks_total", "Total health check invocations", ["result"], registry=registry
)
rpc_latency_histogram = Histogram(
    "eth_rpc_latency_seconds", "RPC call latency", registry=registry
)


class SyncState(str, Enum):
    HEALTHY = "healthy"
    SYNCING = "syncing"
    DEGRADED = "degraded"
    DOWN = "down"


state = {
    "el_status": SyncState.DOWN,
    "cl_status": SyncState.DOWN,
    "block_number": 0,
    "peer_count": 0,
    "el_syncing": True,
    "cl_sync_distance": None,
    "last_check": 0,
}


async def _rpc_call(client: httpx.AsyncClient, method: str, params: list | None = None):
    payload = {"jsonrpc": "2.0", "method": method, "params": params or [], "id": 1}
    start = time.monotonic()
    resp = await client.post(GETH_RPC_URL, json=payload, timeout=10)
    rpc_latency_histogram.observe(time.monotonic() - start)
    data = resp.json()
    if "error" in data:
        raise ValueError(data["error"])
    return data["result"]


async def check_execution_layer(client: httpx.AsyncClient):
    try:
        syncing = await _rpc_call(client, "eth_syncing")
        block_hex = await _rpc_call(client, "eth_blockNumber")
        peers_hex = await _rpc_call(client, "net_peerCount")

        block_num = int(block_hex, 16)
        peer_count = int(peers_hex, 16)

        block_number_gauge.set(block_num)
        peer_count_gauge.set(peer_count)

        state["block_number"] = block_num
        state["peer_count"] = peer_count

        if syncing is False or syncing is None:
            state["el_syncing"] = False
            sync_status_gauge.set(0)
            state["el_status"] = SyncState.HEALTHY if peer_count > 0 else SyncState.DEGRADED
        else:
            state["el_syncing"] = True
            sync_status_gauge.set(1)
            state["el_status"] = SyncState.SYNCING
    except Exception:
        state["el_status"] = SyncState.DOWN
        sync_status_gauge.set(1)


async def check_consensus_layer(client: httpx.AsyncClient):
    try:
        resp = await client.get(f"{LIGHTHOUSE_API_URL}/eth/v1/node/syncing", timeout=10)
        data = resp.json()
        sync_distance = int(data["data"]["sync_distance"])
        cl_sync_distance_gauge.set(sync_distance)
        state["cl_sync_distance"] = sync_distance

        if sync_distance <= 2:
            state["cl_status"] = SyncState.HEALTHY
        elif sync_distance <= 64:
            state["cl_status"] = SyncState.SYNCING
        else:
            state["cl_status"] = SyncState.DEGRADED
    except Exception:
        state["cl_status"] = SyncState.DOWN


async def periodic_check():
    async with httpx.AsyncClient() as client:
        while True:
            await asyncio.gather(
                check_execution_layer(client),
                check_consensus_layer(client),
            )
            overall = (
                "ok"
                if state["el_status"] == SyncState.HEALTHY
                and state["cl_status"] == SyncState.HEALTHY
                else "degraded"
            )
            health_check_counter.labels(result=overall).inc()
            state["last_check"] = int(time.time())
            await asyncio.sleep(CHECK_INTERVAL)


@asynccontextmanager
async def lifespan(application: FastAPI):
    task = asyncio.create_task(periodic_check())
    yield
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


app = FastAPI(title="Ethereum RPC Health Check", lifespan=lifespan)


@app.get("/health")
async def health():
    el = state["el_status"]
    cl = state["cl_status"]

    if el == SyncState.HEALTHY and cl == SyncState.HEALTHY:
        status_code = 200
        overall = "healthy"
    elif el == SyncState.DOWN or cl == SyncState.DOWN:
        status_code = 503
        overall = "down"
    else:
        status_code = 200
        overall = "syncing"

    return Response(
        content=(
            '{"status":"%s","execution":"%s","consensus":"%s",'
            '"block_number":%d,"peer_count":%d,"last_check":%d}'
            % (overall, el, cl, state["block_number"], state["peer_count"], state["last_check"])
        ),
        media_type="application/json",
        status_code=status_code,
    )


@app.get("/health/live")
async def liveness():
    return {"status": "alive"}


@app.get("/health/ready")
async def readiness():
    if state["el_status"] in (SyncState.HEALTHY, SyncState.SYNCING):
        return Response(content='{"ready":true}', media_type="application/json", status_code=200)
    return Response(content='{"ready":false}', media_type="application/json", status_code=503)


@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(registry), media_type="text/plain; charset=utf-8")
