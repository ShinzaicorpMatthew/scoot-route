// Fabrique de chemins GraphHopper SYNTHÉTIQUES, réservés aux tests unitaires.
// L'application n'utilise jamais ces données : elles servent à vérifier les calculs.

/** Ligne droite de `n` points vers l'est à partir de Bellecour, altitude f(i). */
export function fakePath({ n = 41, stepDeg = 0.0005, lat = 45.7578, lon0 = 4.832, ele = () => 170, details = {}, timeS = 600 } = {}) {
  const coords = Array.from({ length: n }, (_, i) => [lon0 + i * stepDeg, lat, ele(i)]);
  // ~39 m par pas de 0.0005° à cette latitude
  const distance = (n - 1) * 0.0005 * 111320 * Math.cos((lat * Math.PI) / 180) * (stepDeg / 0.0005);
  return {
    distance,
    time: timeS * 1000,
    ascend: 0,
    descend: 0,
    points: { type: 'LineString', coordinates: coords },
    instructions: [
      { text: 'Continuez sur Rue Test', street_name: 'Rue Test', distance, time: timeS * 1000, sign: 0, interval: [0, n - 1] },
      { text: 'Arrivée', street_name: '', distance: 0, time: 0, sign: 4, interval: [n - 1, n - 1] },
    ],
    details: {
      road_class: [[0, n - 1, 'RESIDENTIAL']],
      surface: [[0, n - 1, 'ASPHALT']],
      ...details,
    },
  };
}

export const silentLogger = { info() {}, warn() {}, error() {} };
