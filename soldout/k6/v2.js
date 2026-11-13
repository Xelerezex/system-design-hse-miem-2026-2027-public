// HW1 V2 baseline: 30 buyers/s, 60s, 40% targeting the first event sector.
// Discover actual seat IDs from catalog; DB seed IDs are not contiguous per event.
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { Counter, Rate } from 'k6/metrics';
import { uuid } from './lib.js';

const BASE = __ENV.BASE_URL || 'http://soldout:8080';
const EVENT = __ENV.EVENT_ID || '10000000-0000-4000-8000-000000000002';
const RATE = Number(__ENV.V2_RATE || '30');
const DURATION = __ENV.V2_DURATION || '60s';
const HEADERS = { 'Content-Type': 'application/json' };
const serverErrors = new Rate('v2_5xx');
const paid = new Counter('v2_paid');

export const options = {
  scenarios: {
    dynamic_pricing: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 60,
      maxVUs: 100,
    },
  },
  thresholds: {
    checks: ['rate>0.99'],
    http_req_failed: ['rate<0.01'],
    v2_5xx: ['rate==0'],
    dropped_iterations: ['count==0'],
    v2_paid: ['count>0'],
    'http_req_duration{name:hold}': ['p(95)<200', 'p(99)<400'],
    'http_req_duration{name:order}': ['p(99)<500'],
    'http_req_duration{name:pay}': ['p(99)<800'],
  },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
};

function record(res) { serverErrors.add(res.status >= 500); return res; }
function post(path, body, headers, name) {
  return record(http.post(`${BASE}${path}`, body === null ? null : JSON.stringify(body),
    { headers: { ...HEADERS, ...headers }, tags: { name } }));
}
function get(path, name) {
  return record(http.get(`${BASE}${path}`, { tags: { name } }));
}

function chosenSeat(seq) {
  const slot = seq % 10;
  const cycle = Math.floor(seq / 10);
  const sector = slot < 4 ? 0 : 1 + (slot % 3); // 40% hot, 20% in each of the other sectors
  const index = slot < 4 ? cycle * 4 + slot : cycle * 2 + (slot >= 7 ? 1 : 0);
  return { sector, index };
}

function durationSeconds(duration) {
  const match = /^(\d+(?:\.\d+)?)(s|m|h)$/.exec(duration);
  if (!match) throw new Error(`V2_DURATION must be in s, m or h, got ${duration}`);
  return Number(match[1]) * ({ s: 1, m: 60, h: 3600 })[match[2]];
}

// Called once before measurement. Detect invalid/empty event sectors instead of
// issuing thousands of requests with guessed seat IDs.
export function setup() {
  const summary = get(`/v1/events/${EVENT}/seatmap`, 'setup_seatmap');
  if (summary.status !== 200) {
    throw new Error(`V2 setup seatmap: HTTP ${summary.status}: ${String(summary.body).slice(0, 400)}`);
  }
  const summaries = summary.json('sectors');
  if (!Array.isArray(summaries) || summaries.length !== 4) {
    throw new Error(`V2 setup requires exactly four sectors, got ${summaries?.length}`);
  }
  summaries.sort((a, b) => a.id.localeCompare(b.id));
  const sectors = summaries.map((item) => {
    const path = `/v1/events/${EVENT}/sectors/${item.id}/seatmap`;
    const res = get(path, 'setup_sector_map');
    if (res.status !== 200) {
      throw new Error(`V2 setup ${path}: HTTP ${res.status}: ${String(res.body).slice(0, 400)}`);
    }
    const data = res.json();
    if (data.id !== item.id || data.event_id !== EVENT || !Array.isArray(data.seats)) {
      throw new Error(`V2 setup ${path}: invalid sector map response`);
    }
    return {
      id: item.id,
      seats: data.seats.filter((seat) => seat.status === 'free').map((seat) => seat.id),
    };
  });
  const planned = Math.ceil(RATE * durationSeconds(DURATION)) + 1;
  const needed = [0, 0, 0, 0];
  for (let i = 0; i < planned; i++) {
    const { sector, index } = chosenSeat(i);
    needed[sector] = Math.max(needed[sector], index + 1);
  }
  sectors.forEach((sector, i) => {
    if (sector.seats.length < needed[i]) {
      throw new Error(`V2 sector ${sector.id}: ${sector.seats.length} free seats, ${needed[i]} required`);
    }
  });
  console.log(`V2 setup: event=${EVENT}, sector free seats=${sectors.map((s) => s.seats.length).join('/')}, required=${needed.join('/')}`);
  return { sectors };
}

export default function (data) {
  const seq = exec.scenario.iterationInTest;
  const { sector, index } = chosenSeat(seq);
  const sectorId = data.sectors[sector].id;
  const seatId = data.sectors[sector].seats[index];
  if (seatId === undefined) throw new Error(`V2 missing seat in sector ${sectorId}, index=${index}`);
  const userId = uuid();
  const summary = get(`/v1/events/${EVENT}/seatmap`, 'seatmap_summary');
  if (!check(summary, { 'summary 200': (r) => r.status === 200 })) {
    if (__ENV.V2_DEBUG === '1' && seq < 5) console.error(`V2 summary: HTTP ${summary.status}: ${String(summary.body).slice(0, 400)}`);
    return;
  }
  const sectorMap = get(`/v1/events/${EVENT}/sectors/${sectorId}/seatmap`, 'seatmap');
  if (!check(sectorMap, { 'sector map 200': (r) => r.status === 200 })) {
    if (__ENV.V2_DEBUG === '1' && seq < 5) console.error(`V2 sector map: HTTP ${sectorMap.status}: ${String(sectorMap.body).slice(0, 400)}`);
    return;
  }
  const q = post(`/v1/events/${EVENT}/queue/join`, { user_id: userId }, {}, 'queue_join');
  if (!check(q, { 'join 200': (r) => r.status === 200 })) return;
  const token = q.json('token');

  const hold = post('/v1/holds', { event_id: EVENT, seat_id: seatId, user_id: userId },
    { 'X-Admission-Token': token }, 'hold');
  if (!check(hold, { 'priced hold created': (r) => r.status === 201 && r.json('price_minor') > 0 })) {
    if (__ENV.V2_DEBUG === '1' && seq < 5) {
      console.error(`V2 hold failed: HTTP ${hold.status}, seat=${seatId}, sector=${sectorId}, body=${String(hold.body).slice(0, 400)}`);
    }
    return;
  }
  const h = hold.json();
  const o = post('/v1/orders', { hold_ids: [h.id], user_id: userId }, { 'Idempotency-Key': uuid() }, 'order');
  if (!check(o, { 'order sum = hold price': (r) => r.status === 201 && r.json('amount_minor') === h.price_minor })) {
    if (__ENV.V2_DEBUG === '1' && seq < 5) {
      console.error(`V2 order failed: HTTP ${o.status}, expected=${h.price_minor}, body=${String(o.body).slice(0, 400)}`);
    }
    return;
  }
  const p = post(`/v1/orders/${o.json('id')}/pay`, null, {}, 'pay');
  if (!check(p, { 'paid price immutable': (r) => r.status === 200 && r.json('status') === 'paid' && r.json('amount_minor') === h.price_minor })) {
    if (__ENV.V2_DEBUG === '1' && seq < 5) {
      console.error(`V2 pay failed: HTTP ${p.status}, expected=${h.price_minor}, body=${String(p.body).slice(0, 400)}`);
    }
    return;
  }
  paid.add(1);
  const t = get(`/v1/users/${userId}/tickets`, 'tickets');
  check(t, { 'ticket issued': (r) => r.status === 200 && (r.json('tickets') || []).length === 1 });
}
