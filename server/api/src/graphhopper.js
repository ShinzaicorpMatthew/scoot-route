// Client du moteur de routage GraphHopper (auto-hébergé)

export const GH_DETAILS = [
  'street_name', 'road_class', 'road_environment', 'surface', 'smoothness',
  'bike_network', 'get_off_bike', 'max_speed', 'average_slope', 'track_type',
];

export class RoutingError extends Error {
  constructor(message, { status = 502, code = 'routing_error' } = {}) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export function createGraphHopperClient({ baseUrl, profile = 'scooter', timeoutMs = 12000, fetchImpl = fetch }) {
  async function call(path, body) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const res = await fetchImpl(`${baseUrl}${path}`, {
        method: body ? 'POST' : 'GET',
        headers: body ? { 'content-type': 'application/json' } : undefined,
        body: body ? JSON.stringify(body) : undefined,
        signal: ctrl.signal,
      });
      const json = await res.json().catch(() => ({}));
      if (!res.ok) {
        const msg = json?.message || `GraphHopper HTTP ${res.status}`;
        // 400 : point hors carte, aucun chemin praticable, etc.
        throw new RoutingError(msg, { status: res.status === 400 ? 422 : 502, code: res.status === 400 ? 'no_route' : 'engine_error' });
      }
      return json;
    } catch (e) {
      if (e instanceof RoutingError) throw e;
      if (e.name === 'AbortError') throw new RoutingError('Moteur de routage trop lent', { status: 504, code: 'engine_timeout' });
      throw new RoutingError(`Moteur de routage injoignable : ${e.message}`, { status: 503, code: 'engine_unreachable' });
    } finally {
      clearTimeout(timer);
    }
  }

  return {
    /** from/to : [lon, lat] */
    async route(from, to, customModel, { alternatives = 0, heading } = {}) {
      const body = {
        profile,
        points: [from, to],
        elevation: true,
        points_encoded: false,
        instructions: true,
        locale: 'fr',
        details: GH_DETAILS,
        'ch.disable': true,
        custom_model: customModel,
      };
      if (Number.isFinite(heading)) {
        // Cap de départ (recalcul en roulant) : évite de proposer un demi-tour immédiat
        body.headings = [heading];
        body.heading_penalty = 120;
      }
      if (alternatives > 0) {
        body.algorithm = 'alternative_route';
        body['alternative_route.max_paths'] = alternatives + 1;
        body['alternative_route.max_weight_factor'] = 1.6;
        body['alternative_route.max_share_factor'] = 0.7;
      }
      const json = await call('/route', body);
      if (!Array.isArray(json.paths) || json.paths.length === 0) {
        throw new RoutingError('Aucun itinéraire trouvé', { status: 422, code: 'no_route' });
      }
      return json.paths;
    },

    async info() {
      return call('/info');
    },
  };
}
