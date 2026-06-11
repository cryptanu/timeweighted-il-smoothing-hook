import React, { useMemo, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Activity, BarChart3, Clock, Droplets, ShieldCheck } from 'lucide-react';
import './styles.css';

type Lp = {
  name: string;
  hours: number;
  deposit: number;
};

const tiers = [
  { label: '< 1h', factor: 0 },
  { label: '1-6h', factor: 25 },
  { label: '6-12h', factor: 50 },
  { label: '> 12h', factor: 75 }
];

function factorForHours(hours: number) {
  if (hours <= 1) return 0;
  if (hours <= 6) return 25;
  if (hours <= 12) return 50;
  return 75;
}

function ilPercent(priceMove: number) {
  const k = priceMove;
  return Math.max(0, 1 - (2 * Math.sqrt(k)) / (1 + k)) * 100;
}

function App() {
  const [priceMove, setPriceMove] = useState(2);
  const [reserve, setReserve] = useState(10000);
  const [lpA, setLpA] = useState<Lp>({ name: 'LP A', hours: 2, deposit: 1000 });
  const [lpB, setLpB] = useState<Lp>({ name: 'LP B', hours: 13, deposit: 1000 });

  const rows = useMemo(() => {
    const totalDeposits = lpA.deposit + lpB.deposit;
    return [lpA, lpB].map((lp) => {
      const il = (lp.deposit * ilPercent(priceMove)) / 100;
      const factor = factorForHours(lp.hours);
      const requested = (il * factor) / 100;
      const entitlement = totalDeposits === 0 ? 0 : (reserve * lp.deposit) / totalDeposits;
      const payout = Math.min(requested, entitlement);
      return { ...lp, il, factor, requested, entitlement, payout, netIl: il - payout };
    });
  }, [lpA, lpB, priceMove, reserve]);

  return (
    <main className="shell">
      <section className="topbar">
        <div>
          <h1>TimeWeightedILSmoothing</h1>
          <p>Stay longer, suffer less</p>
        </div>
        <div className="status">
          <ShieldCheck size={18} />
          <span>Standalone v4 hook</span>
        </div>
      </section>

      <section className="metrics">
        <Metric icon={<Droplets />} label="Smoothing reserve" value={`${reserve.toLocaleString()} token0`} />
        <Metric icon={<Activity />} label="Price move" value={`${priceMove.toFixed(2)}x`} />
        <Metric icon={<BarChart3 />} label="Computed IL" value={`${ilPercent(priceMove).toFixed(2)}%`} />
        <Metric icon={<Clock />} label="Max coverage" value="75%" />
      </section>

      <section className="controls">
        <label>
          Price move
          <input min="0.25" max="4" step="0.05" type="range" value={priceMove} onChange={(e) => setPriceMove(Number(e.target.value))} />
        </label>
        <label>
          Reserve token0
          <input type="number" value={reserve} onChange={(e) => setReserve(Number(e.target.value))} />
        </label>
      </section>

      <section className="grid">
        {[lpA, lpB].map((lp, idx) => (
          <div className="panel" key={lp.name}>
            <h2>{lp.name}</h2>
            <label>
              Tenure hours
              <input
                type="number"
                value={lp.hours}
                onChange={(e) => (idx === 0 ? setLpA({ ...lpA, hours: Number(e.target.value) }) : setLpB({ ...lpB, hours: Number(e.target.value) }))}
              />
            </label>
            <label>
              Deposit token0
              <input
                type="number"
                value={lp.deposit}
                onChange={(e) => (idx === 0 ? setLpA({ ...lpA, deposit: Number(e.target.value) }) : setLpB({ ...lpB, deposit: Number(e.target.value) }))}
              />
            </label>
          </div>
        ))}
      </section>

      <section className="tableWrap">
        <table>
          <thead>
            <tr>
              <th>LP</th>
              <th>Tier</th>
              <th>IL</th>
              <th>Requested</th>
              <th>Entitlement</th>
              <th>Payout</th>
              <th>Net IL</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.name}>
                <td>{row.name}</td>
                <td>{row.factor}%</td>
                <td>{row.il.toFixed(2)}</td>
                <td>{row.requested.toFixed(2)}</td>
                <td>{row.entitlement.toFixed(2)}</td>
                <td>{row.payout.toFixed(2)}</td>
                <td>{row.netIl.toFixed(2)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      <section className="tiers">
        {tiers.map((tier) => (
          <div key={tier.label}>
            <span>{tier.label}</span>
            <strong>{tier.factor}%</strong>
          </div>
        ))}
      </section>
    </main>
  );
}

function Metric({ icon, label, value }: { icon: React.ReactNode; label: string; value: string }) {
  return (
    <div className="metric">
      <div className="metricIcon">{icon}</div>
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}

createRoot(document.getElementById('root')!).render(<App />);

