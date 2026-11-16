import React, { useState, useMemo, useEffect } from 'react';
import {
  Activity,
  ShieldCheck,
  Database,
  MessageSquare,
  BarChart3,
  AlertTriangle,
  CheckCircle2,
  Send,
  Layers,
  ExternalLink,
  Info,
  Sparkles,
  Lock
} from 'lucide-react';
import { ConversationalIngestionPipeline } from '../orchestration/ingestionPipeline.js';
import { runMedallionPipeline } from '../warehouse/medallionTransforms.js';
import { evaluateLongitudinalAnalytics } from '../analytics/illustrativeModeling.js';
import demoBundle from '../data/precomputedDemoBundle.json';

const TAG_BADGE_STYLES = {
  HIGH_FODMAP_POLYOL: 'bg-rose-500/15 text-rose-300 border-rose-500/40',
  FERMENTABLE_OLIGOSACCHARIDE: 'bg-orange-500/15 text-orange-300 border-orange-500/40',
  HYDROCOLLOID_GUM: 'bg-amber-500/15 text-amber-300 border-amber-500/40',
  EMULSIFIER_IRRITANT: 'bg-purple-500/15 text-purple-300 border-purple-500/40',
  DAIRY_DERIVED: 'bg-sky-500/15 text-sky-300 border-sky-500/40',
  GLUTEN_RISK: 'bg-red-500/15 text-red-300 border-red-500/40',
  HIDDEN_ALLIUM_RISK: 'bg-yellow-500/15 text-yellow-300 border-yellow-500/40',
  SEED_OIL: 'bg-slate-500/20 text-slate-300 border-slate-500/40',
  LOW_RISK_POLYOL: 'bg-emerald-500/15 text-emerald-300 border-emerald-500/40'
};

function getInitialParams() {
  if (typeof window === 'undefined') return { tab: 'overview', preset: 'resolved' };
  const params = new URLSearchParams(window.location.search);
  return {
    tab: params.get('tab') || 'overview',
    preset: params.get('preset') || 'resolved'
  };
}

function buildInitialConversation(presetMode) {
  const pipe = new ConversationalIngestionPipeline();
  const messages = [];
  let latestResult = null;

  if (presetMode === 'ambiguous') {
    const userText = 'Had pasta and a side salad at 1pm';
    const res1 = pipe.ingestMessage({
      tenant_id: 'demo_persona_alex',
      session_id: 'ui_demo_session',
      raw_text: userText,
      reference_timestamp: '2026-10-14T20:00:00.000Z'
    });
    messages.push({ role: 'user', text: userText, timestamp: '13:00 UTC (parsed)' });
    messages.push({
      role: 'gatekeeper',
      status: 'NEEDS_CLARIFICATION',
      reasons: res1.gatekeeper.ambiguity_reasons,
      text: res1.followup_prompt
    });
    latestResult = res1;
  } else if (presetMode === 'additive_audit') {
    const userText = 'Scanned barcode 0074312098765 — afternoon chocolate protein shake';
    const res = pipe.ingestMessage({
      tenant_id: 'demo_persona_alex',
      session_id: 'ui_demo_session_barcode',
      modality: 'barcode',
      barcode_gtin13: '0074312098765',
      raw_text: userText,
      reference_timestamp: '2026-10-14T15:30:00.000Z'
    });
    messages.push({ role: 'user', text: userText, timestamp: '15:30 UTC' });
    messages.push({
      role: 'system_complete',
      event: res.persisted_event
    });
    latestResult = res;
  } else {
    const t1Text = 'Had pasta and a side salad at 1pm';
    const res1 = pipe.ingestMessage({
      tenant_id: 'demo_persona_alex',
      session_id: 'ui_demo_session',
      raw_text: t1Text,
      reference_timestamp: '2026-10-14T20:00:00.000Z'
    });
    messages.push({ role: 'user', text: t1Text, timestamp: 'Turn 1' });
    messages.push({
      role: 'gatekeeper',
      status: 'NEEDS_CLARIFICATION',
      reasons: res1.gatekeeper.ambiguity_reasons,
      text: res1.followup_prompt
    });

    const t2Text = 'Certified gluten-free brown rice pasta and raw spinach with olive oil and lemon';
    const res2 = pipe.ingestMessage({
      tenant_id: 'demo_persona_alex',
      session_id: 'ui_demo_session',
      raw_text: t2Text,
      reference_timestamp: '2026-10-14T20:01:15.000Z'
    });
    messages.push({ role: 'user', text: t2Text, timestamp: 'Turn 2 (Clarification)' });
    messages.push({
      role: 'system_complete',
      event: res2.persisted_event
    });
    latestResult = res2;
  }

  return { pipe, messages, latestResult };
}

export default function App() {
  const initial = useMemo(() => getInitialParams(), []);
  const [activeTab, setActiveTab] = useState(initial.tab);
  const [selectedTenant, setSelectedTenant] = useState('demo_persona_alex');
  const [medallionLayer, setMedallionLayer] = useState('gold');

  const initialConv = useMemo(() => buildInitialConversation(initial.preset), [initial.preset]);
  const [pipeline] = useState(() => initialConv.pipe);
  const [chatHistory, setChatHistory] = useState(initialConv.messages);
  const [inspectorData, setInspectorData] = useState(initialConv.latestResult);
  const [inputValue, setInputValue] = useState('');
  const [sessionCounter, setSessionCounter] = useState(10);

  const [sessionId, setSessionId] = useState('ui_demo_session');

  useEffect(() => {
    // Keep session ID synchronized with tenant switches to preserve strict isolation
    setSessionId(`sess_${selectedTenant}_${sessionCounter}`);
  }, [selectedTenant, sessionCounter]);

  const tenantEvents = useMemo(
    () => demoBundle.events.filter((e) => e.tenant_id === selectedTenant),
    [selectedTenant]
  );

  const tenantMedallion = useMemo(() => runMedallionPipeline(tenantEvents), [tenantEvents]);

  const tenantAnalytics = useMemo(
    () =>
      demoBundle.analytics_by_tenant[selectedTenant] ||
      evaluateLongitudinalAnalytics(tenantMedallion.gold, selectedTenant),
    [selectedTenant, tenantMedallion]
  );

  const handleSendMessage = (overrideText = null, options = {}) => {
    const text = (overrideText ?? inputValue).trim();
    if (!text) return;

    const activeSess = options.newSession
      ? `sess_${selectedTenant}_${sessionCounter + 1}`
      : sessionId;
    if (options.newSession) {
      setSessionCounter((c) => c + 1);
      setSessionId(activeSess);
    }

    const nowIso = '2026-10-14T20:05:00.000Z';
    const result = pipeline.ingestMessage({
      tenant_id: selectedTenant,
      session_id: activeSess,
      modality: options.modality || 'text',
      barcode_gtin13: options.barcode || null,
      raw_text: text,
      reference_timestamp: nowIso
    });

    const nextMessages = options.resetHistory ? [] : [...chatHistory];
    nextMessages.push({ role: 'user', text, timestamp: 'Live Demo Turn' });

    if (result.status === 'NEEDS_CLARIFICATION') {
      nextMessages.push({
        role: 'gatekeeper',
        status: 'NEEDS_CLARIFICATION',
        reasons: result.gatekeeper.ambiguity_reasons,
        text: result.followup_prompt
      });
    } else {
      nextMessages.push({
        role: 'system_complete',
        event: result.persisted_event
      });
    }

    setChatHistory(nextMessages);
    setInspectorData(result);
    setInputValue('');
  };

  const loadScenario = (mode) => {
    const fresh = buildInitialConversation(mode);
    setChatHistory(fresh.messages);
    setInspectorData(fresh.latestResult);
  };

  return (
    <div className="min-h-screen flex flex-col bg-[#090d16] text-slate-100">
      {/* Top Non-Clinical & Synthetic Safeguard Banner */}
      <div className="bg-amber-500/10 border-b border-amber-500/25 px-4 py-2 text-xs text-amber-200/90">
        <div className="max-w-7xl mx-auto flex flex-wrap items-center justify-between gap-2">
          <div className="flex items-center gap-2">
            <ShieldCheck className="w-4 h-4 text-amber-400 shrink-0" />
            <span>
              <strong>Sanitized Engineering Showcase:</strong> Populated 100% with deterministic synthetic records (seed{' '}
              <code>20261114</code>). Not a medical device, clinical diagnostic tool, or causal dietary advisor.
            </span>
          </div>
          <span className="font-mono text-[11px] px-2 py-0.5 rounded bg-slate-900 border border-amber-500/30 text-amber-300">
            OFFLINE ADAPTER MODE • ZERO CREDENTIALS
          </span>
        </div>
      </div>

      {/* DBMarketer Branded Header */}
      <header className="border-b border-slate-800/90 bg-slate-950/80 backdrop-blur">
        <div className="max-w-7xl mx-auto px-6 py-5 flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
          <div>
            <div className="flex items-center gap-2.5">
              <div className="w-8 h-8 rounded-lg bg-amber-500/15 border border-amber-500/40 flex items-center justify-center">
                <Activity className="w-4 h-4 text-amber-400" />
              </div>
              <span className="text-xs font-semibold uppercase tracking-widest text-amber-400">
                DBMarketer Portfolio Architecture
              </span>
              <span className="text-slate-600">•</span>
              <a
                href="https://dbmarketer.com"
                target="_blank"
                rel="noopener noreferrer"
                className="text-xs text-slate-400 hover:text-amber-300 inline-flex items-center gap-1 transition-colors"
              >
                dbmarketer.com <ExternalLink className="w-3 h-3" />
              </a>
            </div>
            <h1 className="text-xl sm:text-2xl font-semibold tracking-tight text-white mt-1.5">
              DBMarketer | AI Nutrition &amp; Ingredient Intelligence
            </h1>
            <p className="text-sm text-slate-400 mt-0.5">
              Multimodal AI, Governed Data Pipelines &amp; Applied Analytics
            </p>
          </div>

          {/* Tenant Isolation Switcher & Navigation */}
          <div className="flex flex-wrap items-center gap-3">
            <div className="flex items-center gap-2 bg-slate-900 border border-slate-800 rounded-lg px-3 py-1.5">
              <Lock className="w-3.5 h-3.5 text-emerald-400" />
              <span className="text-xs text-slate-400">Synthetic Tenant:</span>
              <select
                aria-label="Select Synthetic Tenant"
                value={selectedTenant}
                onChange={(e) => setSelectedTenant(e.target.value)}
                className="bg-transparent text-xs font-mono text-emerald-300 focus:outline-none"
              >
                <option value="demo_persona_alex" className="bg-slate-900">
                  demo_persona_alex (60d)
                </option>
                <option value="demo_persona_maya" className="bg-slate-900">
                  demo_persona_maya (30d)
                </option>
              </select>
            </div>
          </div>
        </div>

        {/* Navigation Tabs */}
        <div className="max-w-7xl mx-auto px-6 flex gap-1 overflow-x-auto">
          {[
            { id: 'overview', label: '1. Executive & System Overview', icon: Sparkles },
            { id: 'conversational', label: '2. Gatekeeper & Schema Extraction', icon: MessageSquare },
            { id: 'analytics', label: '3. Longitudinal Analytics & Forecast', icon: BarChart3 },
            { id: 'lineage', label: '4. Medallion Warehouse (Bronze → Gold)', icon: Layers }
          ].map((t) => {
            const Icon = t.icon;
            const active = activeTab === t.id;
            return (
              <button
                key={t.id}
                onClick={() => setActiveTab(t.id)}
                className={`flex items-center gap-2 px-4 py-3 text-sm font-medium border-b-2 transition-colors whitespace-nowrap ${
                  active
                    ? 'border-amber-400 text-amber-300 bg-amber-500/5'
                    : 'border-transparent text-slate-400 hover:text-slate-200 hover:border-slate-700'
                }`}
              >
                <Icon className="w-4 h-4" />
                {t.label}
              </button>
            );
          })}
        </div>
      </header>

      {/* Main Content */}
      <main className="max-w-7xl w-full mx-auto px-6 py-6 flex-1 space-y-6">
        {activeTab === 'overview' && (
          <OverviewSection
            tenantId={selectedTenant}
            events={tenantEvents}
            analytics={tenantAnalytics}
            onNavigate={setActiveTab}
          />
        )}

        {activeTab === 'conversational' && (
          <ConversationalSandboxSection
            chatHistory={chatHistory}
            inspectorData={inspectorData}
            inputValue={inputValue}
            setInputValue={setInputValue}
            onSend={handleSendMessage}
            onLoadScenario={loadScenario}
          />
        )}

        {activeTab === 'analytics' && (
          <AnalyticsDashboardSection
            tenantId={selectedTenant}
            analytics={tenantAnalytics}
          />
        )}

        {activeTab === 'lineage' && (
          <MedallionLineageSection
            medallion={tenantMedallion}
            activeLayer={medallionLayer}
            setActiveLayer={setMedallionLayer}
          />
        )}
      </main>

      {/* Footer */}
      <footer className="border-t border-slate-800/80 bg-slate-950 py-4 px-6 text-xs text-slate-500">
        <div className="max-w-7xl mx-auto flex flex-col sm:flex-row justify-between items-center gap-2">
          <span>
            Engineered by <strong>Rudy Martinez</strong> •{' '}
            <a href="https://dbmarketer.com" className="text-slate-300 hover:text-amber-300 underline">
              DBMarketer (dbmarketer.com)
            </a>
          </span>
          <span>
            Public Demonstration Repository • Zero PHI • Strict Zod + Medallion SQL Contracts
          </span>
        </div>
      </footer>
    </div>
  );
}

function OverviewSection({ tenantId, events, analytics, onNavigate }) {
  const foodEvents = events.filter((e) => e.category === 'food');
  const clarifiedCount = foodEvents.filter((e) => e.clarification_turns > 0).length;
  const alertEvents = foodEvents.filter((e) => e.system_alerts.length > 0).length;

  return (
    <div className="space-y-6">
      {/* KPI Strip */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <div className="bg-slate-900/80 border border-slate-800 rounded-xl p-4">
          <p className="text-xs uppercase tracking-wider text-slate-400">Synthetic Event Stream</p>
          <p className="text-2xl font-semibold text-white mt-1">{events.length} Events</p>
          <p className="text-xs text-emerald-400 mt-1 font-mono">100% Zod Contract Validated</p>
        </div>
        <div className="bg-slate-900/80 border border-slate-800 rounded-xl p-4">
          <p className="text-xs uppercase tracking-wider text-slate-400">Gatekeeper Clarifications</p>
          <p className="text-2xl font-semibold text-white mt-1">
            {Math.round((clarifiedCount / Math.max(1, foodEvents.length)) * 100)}% of Meals
          </p>
          <p className="text-xs text-amber-300 mt-1">Intercepted missing prep / allergen state</p>
        </div>
        <div className="bg-slate-900/80 border border-slate-800 rounded-xl p-4">
          <p className="text-xs uppercase tracking-wider text-slate-400">Additive Taxonomy Alerts</p>
          <p className="text-2xl font-semibold text-white mt-1">{alertEvents} Flagged Meals</p>
          <p className="text-xs text-slate-400 mt-1">Polyols, gums, emulsifiers &amp; alliums</p>
        </div>
        <div className="bg-slate-900/80 border border-slate-800 rounded-xl p-4">
          <p className="text-xs uppercase tracking-wider text-slate-400">Held-Out Chronological AUC</p>
          <p className="text-2xl font-semibold text-white mt-1">
            {analytics.validation_metrics.held_out_roc_auc.toFixed(2)}
          </p>
          <p className="text-xs text-slate-400 mt-1">
            75/25 temporal split ({analytics.sample_summary.validation_observations} eval days)
          </p>
        </div>
      </div>

      {/* End-to-End Architecture Pipeline Strip */}
      <div className="bg-slate-900/70 border border-slate-800 rounded-xl p-6">
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-2 mb-5">
          <div>
            <h2 className="text-base font-semibold text-white">
              End-to-End System Architecture: From Unstructured Meal Logs to Governed Warehouse Features
            </h2>
            <p className="text-xs text-slate-400 mt-0.5">
              Multi-stage validation prevents ambiguous free-text inputs from polluting downstream statistical features.
            </p>
          </div>
          <button
            onClick={() => onNavigate('conversational')}
            className="text-xs px-3 py-1.5 rounded-lg bg-amber-500/15 text-amber-300 border border-amber-500/40 hover:bg-amber-500/25 transition-colors self-start"
          >
            Inspect Gatekeeper Sandbox →
          </button>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-4 gap-3">
          {[
            {
              step: 'Stage 1 • Gatekeeper',
              title: 'Ambiguity & Modality Routing',
              desc: 'Classifies text/barcode/photo inputs. Pauses persistence when composite meals omit prep state, sauces, or gluten verification.'
            },
            {
              step: 'Stage 2 • Extraction',
              title: 'Strict Zod JSON Contract',
              desc: 'Normalizes relative time expressions to UTC ISO-8601 and enforces category-specific nested metadata contracts.'
            },
            {
              step: 'Stage 3 • Taxonomy Audit',
              title: 'Ingredient & Excipient Rules',
              desc: 'Decomposes packaged foods to flag osmotic polyols (E420/E965/E966), hydrocolloid gums, and emulsifiers.'
            },
            {
              step: 'Stage 4 • Medallion & ML',
              title: 'Tenant-Isolated Lag Marts',
              desc: 'Transforms Bronze JSON into Silver 0/1 flags and Gold strictly-prior 24h/48h exposure windows for baseline forecasting.'
            }
          ].map((stage) => (
            <div key={stage.step} className="bg-slate-950/80 border border-slate-800/90 rounded-lg p-4">
              <span className="text-[11px] font-mono uppercase tracking-wider text-amber-400">{stage.step}</span>
              <h3 className="text-sm font-semibold text-white mt-1">{stage.title}</h3>
              <p className="text-xs text-slate-400 mt-1.5 leading-relaxed">{stage.desc}</p>
            </div>
          ))}
        </div>
      </div>

      {/* Two-Column Preview: Forecast Mini-Preview + Recent Synthetic Stream */}
      <div className="grid grid-cols-1 lg:grid-cols-12 gap-6">
        <div className="lg:col-span-7 bg-slate-900/70 border border-slate-800 rounded-xl p-5">
          <div className="flex items-center justify-between mb-3">
            <div>
              <h3 className="text-sm font-semibold text-white">
                60-Day Longitudinal Discomfort Score vs. Rolling 7-Day Baseline ({tenantId})
              </h3>
              <p className="text-xs text-slate-400">
                Shaded band indicates 95% rolling prediction interval; rose markers denote above-band flare days.
              </p>
            </div>
            <button
              onClick={() => onNavigate('analytics')}
              className="text-xs text-amber-300 hover:underline"
            >
              Full Analytics →
            </button>
          </div>
          <ForecastSvgChart series={analytics.daily_forecast_series} compact />
        </div>

        <div className="lg:col-span-5 bg-slate-900/70 border border-slate-800 rounded-xl p-5">
          <div className="flex items-center justify-between mb-3">
            <h3 className="text-sm font-semibold text-white">Recent Validated Events (Synthetic Feed)</h3>
            <span className="text-[11px] font-mono text-emerald-400">{tenantId}</span>
          </div>
          <div className="space-y-2.5 max-h-64 overflow-y-auto pr-1">
            {events.slice(-6).reverse().map((evt) => (
              <div key={evt.event_id} className="p-3 rounded-lg bg-slate-950/90 border border-slate-800/80 text-xs">
                <div className="flex items-center justify-between text-slate-400 font-mono text-[11px]">
                  <span className="uppercase text-amber-300 font-semibold">{evt.category}</span>
                  <span>{evt.event_timestamp.slice(0, 16).replace('T', ' ')} UTC</span>
                </div>
                <p className="text-slate-200 mt-1">{evt.raw_text}</p>
                {evt.system_alerts?.length > 0 && (
                  <div className="mt-1.5 flex items-center gap-1.5 text-rose-300 text-[11px]">
                    <AlertTriangle className="w-3.5 h-3.5 shrink-0" />
                    <span className="truncate">{evt.system_alerts[0]}</span>
                  </div>
                )}
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

function ConversationalSandboxSection({
  chatHistory,
  inspectorData,
  inputValue,
  setInputValue,
  onSend,
  onLoadScenario
}) {
  const persisted = inspectorData?.persisted_event;

  return (
    <div className="grid grid-cols-1 lg:grid-cols-12 gap-6">
      {/* Left: Conversational Interface */}
      <div className="lg:col-span-6 bg-slate-900/80 border border-slate-800 rounded-xl flex flex-col overflow-hidden">
        <div className="p-4 border-b border-slate-800 bg-slate-950/60 flex flex-wrap items-center justify-between gap-2">
          <div>
            <h2 className="text-sm font-semibold text-white">Conversational Ingestion &amp; Clarification Loop</h2>
            <p className="text-xs text-slate-400">Test how ambiguous entries pause persistence until required attributes are resolved.</p>
          </div>
          <div className="flex flex-wrap gap-1.5">
            <button
              onClick={() => onLoadScenario('ambiguous')}
              className="text-[11px] px-2.5 py-1 rounded bg-amber-500/15 text-amber-300 border border-amber-500/30 hover:bg-amber-500/25"
            >
              1. Ambiguous Meal
            </button>
            <button
              onClick={() => onLoadScenario('resolved')}
              className="text-[11px] px-2.5 py-1 rounded bg-emerald-500/15 text-emerald-300 border border-emerald-500/30 hover:bg-emerald-500/25"
            >
              2. Clarified Resolution
            </button>
            <button
              onClick={() => onLoadScenario('additive_audit')}
              className="text-[11px] px-2.5 py-1 rounded bg-rose-500/15 text-rose-300 border border-rose-500/30 hover:bg-rose-500/25"
            >
              3. Barcode Polyol Audit
            </button>
          </div>
        </div>

        {/* Message Thread */}
        <div className="p-5 space-y-4 flex-1 min-h-[360px] max-h-[480px] overflow-y-auto">
          {chatHistory.map((msg, idx) => {
            if (msg.role === 'user') {
              return (
                <div key={idx} className="flex justify-end">
                  <div className="max-w-[85%] rounded-xl rounded-br-sm bg-amber-500/15 border border-amber-500/35 px-4 py-3">
                    <div className="text-[10px] font-mono uppercase text-amber-300/80 mb-1">
                      User Input • {msg.timestamp}
                    </div>
                    <p className="text-sm text-slate-100">{msg.text}</p>
                  </div>
                </div>
              );
            }
            if (msg.role === 'gatekeeper') {
              return (
                <div key={idx} className="flex justify-start">
                  <div className="max-w-[90%] rounded-xl rounded-bl-sm bg-slate-950 border-l-4 border-amber-400 border-y border-r border-slate-800 px-4 py-3">
                    <div className="flex items-center gap-2 text-xs font-semibold text-amber-300 mb-1">
                      <AlertTriangle className="w-4 h-4" />
                      Gatekeeper Intercept: NEEDS_CLARIFICATION
                    </div>
                    <p className="text-sm text-slate-200 leading-relaxed">{msg.text}</p>
                    <div className="flex flex-wrap gap-1.5 mt-2.5">
                      {msg.reasons.map((r) => (
                        <span
                          key={r}
                          className="text-[10px] font-mono px-2 py-0.5 rounded bg-amber-500/10 text-amber-300 border border-amber-500/25"
                        >
                          {r}
                        </span>
                      ))}
                    </div>
                  </div>
                </div>
              );
            }
            return (
              <div key={idx} className="flex justify-start">
                <div className="max-w-[92%] rounded-xl rounded-bl-sm bg-emerald-950/30 border border-emerald-500/35 px-4 py-3 space-y-2">
                  <div className="flex items-center justify-between gap-2">
                    <span className="inline-flex items-center gap-1.5 text-xs font-semibold text-emerald-300">
                      <CheckCircle2 className="w-4 h-4" />
                      Contract Validated &amp; Persisted ({msg.event.event_id})
                    </span>
                    <span className="text-[10px] font-mono text-slate-400">
                      {msg.event.event_timestamp}
                    </span>
                  </div>
                  {msg.event.food_metadata && (
                    <p className="text-xs text-slate-200">
                      <strong>Resolved:</strong> {msg.event.food_metadata.resolved_food_name} (
                      <code>prep={msg.event.food_metadata.prep_state}</code>,{' '}
                      <code>gf_verified={String(msg.event.food_metadata.gluten_free_verified)}</code>)
                    </p>
                  )}
                  {msg.event.system_alerts?.length > 0 && (
                    <div className="space-y-1 pt-1">
                      {msg.event.system_alerts.map((al, i) => (
                        <div
                          key={i}
                          className="text-[11px] px-2.5 py-1.5 rounded bg-rose-950/60 border border-rose-500/40 text-rose-200"
                        >
                          {al}
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </div>
            );
          })}
        </div>

        {/* Input Form */}
        <form
          onSubmit={(e) => {
            e.preventDefault();
            onSend();
          }}
          className="p-3 border-t border-slate-800 bg-slate-950/80 flex gap-2"
        >
          <input
            type="text"
            value={inputValue}
            onChange={(e) => setInputValue(e.target.value)}
            placeholder="Try: 'Had tacos for lunch' or 'Cooked salmon with steamed zucchini at 7pm'..."
            className="flex-1 bg-slate-900 border border-slate-700 rounded-lg px-3.5 py-2 text-sm text-white placeholder-slate-500 focus:outline-none focus:border-amber-400"
          />
          <button
            type="submit"
            className="px-4 py-2 rounded-lg bg-amber-500 text-slate-950 font-semibold text-sm hover:bg-amber-400 transition-colors inline-flex items-center gap-1.5"
          >
            <Send className="w-4 h-4" /> Send
          </button>
        </form>
      </div>

      {/* Right: Structured Event & Taxonomy Inspector */}
      <div className="lg:col-span-6 bg-slate-900/80 border border-slate-800 rounded-xl p-5 flex flex-col space-y-4">
        <div className="flex items-center justify-between border-b border-slate-800 pb-3">
          <div>
            <h2 className="text-sm font-semibold text-white">Gatekeeper &amp; Zod Schema Contract Inspector</h2>
            <p className="text-xs text-slate-400">Live inspection of routing state, decomposed ingredient tags, and canonical payload.</p>
          </div>
          <span
            className={`text-xs font-mono px-2.5 py-1 rounded border ${
              inspectorData?.status === 'COMPLETE'
                ? 'bg-emerald-500/15 text-emerald-300 border-emerald-500/40'
                : 'bg-amber-500/15 text-amber-300 border-amber-500/40'
            }`}
          >
            {inspectorData?.status || 'IDLE'}
          </span>
        </div>

        {persisted?.food_metadata && (
          <div>
            <h3 className="text-xs font-semibold uppercase tracking-wider text-slate-400 mb-2">
              Decomposed Ingredient &amp; Additive Taxonomy
            </h3>
            <div className="flex flex-wrap gap-2">
              {persisted.food_metadata.ingredients.map((ing, i) => (
                <div
                  key={i}
                  className="px-2.5 py-1.5 rounded-lg bg-slate-950 border border-slate-800 text-xs flex items-center gap-2"
                >
                  <span className="text-slate-200 font-medium">{ing.name}</span>
                  {ing.tags.map((tag) => (
                    <span
                      key={tag}
                      className={`text-[10px] font-mono px-1.5 py-0.5 rounded border ${
                        TAG_BADGE_STYLES[tag] || 'bg-slate-800 text-slate-300'
                      }`}
                    >
                      {tag}
                    </span>
                  ))}
                </div>
              ))}
            </div>
          </div>
        )}

        <div className="flex-1">
          <h3 className="text-xs font-semibold uppercase tracking-wider text-slate-400 mb-2">
            Validated JSON Payload (Operational → Warehouse Bronze Contract)
          </h3>
          <pre className="bg-slate-950 border border-slate-800 rounded-lg p-3.5 text-[11px] leading-relaxed text-emerald-200/90 whitespace-pre-wrap break-words max-h-[320px] overflow-y-auto">
            {JSON.stringify(persisted || inspectorData?.gatekeeper, null, 2)}
          </pre>
        </div>
      </div>
    </div>
  );
}

function AnalyticsDashboardSection({ tenantId, analytics }) {
  return (
    <div className="space-y-6">
      {/* Methodological Governance Callout */}
      <div className="bg-slate-900/90 border-l-4 border-amber-400 border-y border-r border-slate-800 rounded-xl p-4 flex items-start gap-3">
        <Info className="w-5 h-5 text-amber-400 shrink-0 mt-0.5" />
        <div className="text-xs text-slate-300 space-y-1 leading-relaxed">
          <p className="font-semibold text-white">
            Analytical Governance: Observational Predictive Association ≠ Causal Inference
          </p>
          <p>
            Attributions and risk ratios below are estimated on chronological synthetic logs (
            <code>{analytics.governance.split_strategy}</code>, held-out ROC-AUC{' '}
            <code>{analytics.validation_metrics.held_out_roc_auc}</code>). Because packaged foods bundle multiple
            additives simultaneously (e.g., maltitol + hydrocolloid gums + emulsifiers), feature weights reflect
            predictive signal under collinearity—not isolated biological causation. They serve as structured prompts
            for controlled dietary review.
          </p>
        </div>
      </div>

      {/* Longitudinal Time-Series Forecast Chart */}
      <div className="bg-slate-900/80 border border-slate-800 rounded-xl p-5">
        <div className="flex flex-wrap items-center justify-between gap-2 mb-4">
          <div>
            <h2 className="text-base font-semibold text-white">
              Longitudinal Discomfort Score &amp; Rolling 95% Baseline Forecast ({tenantId})
            </h2>
            <p className="text-xs text-slate-400">
              Daily maximum discomfort (1–10) plotted against rolling 7-day baseline expectation and 95% upper anomaly threshold.
            </p>
          </div>
          <div className="flex items-center gap-4 text-xs">
            <span className="inline-flex items-center gap-1.5 text-amber-300">
              <span className="w-2.5 h-2.5 rounded-full bg-amber-400"></span> Observed Score
            </span>
            <span className="inline-flex items-center gap-1.5 text-sky-300">
              <span className="w-3 h-0.5 bg-sky-400"></span> 7d Baseline
            </span>
            <span className="inline-flex items-center gap-1.5 text-rose-300">
              <span className="w-2.5 h-2.5 rounded-full bg-rose-500"></span> Anomaly Spike (&gt;95% Band)
            </span>
          </div>
        </div>
        <ForecastSvgChart series={analytics.daily_forecast_series} />
      </div>

      {/* Feature Attribution + Collinearity Diagnostics */}
      <div className="grid grid-cols-1 lg:grid-cols-12 gap-6">
        <div className="lg:col-span-8 bg-slate-900/80 border border-slate-800 rounded-xl p-5">
          <h3 className="text-sm font-semibold text-white mb-1">
            Held-Out Lagged Feature Associations (Prior 24h / 48h Windows)
          </h3>
          <p className="text-xs text-slate-400 mb-4">
            Permutation log-loss attribution share paired with Haldane-corrected observational risk ratios and 95% confidence intervals.
          </p>
          <div className="space-y-3">
            {analytics.feature_attributions.map((feat) => {
              const pct = Math.round(feat.relative_attribution_share * 100);
              return (
                <div key={feat.feature} className="space-y-1">
                  <div className="flex flex-wrap justify-between text-xs gap-2">
                    <span className="text-slate-200 font-medium">{feat.label}</span>
                    <span className="font-mono text-slate-300">
                      Share: <strong className="text-amber-300">{pct}%</strong> • Obs RR:{' '}
                      <strong className="text-emerald-300">{feat.observational_risk_ratio}x</strong>{' '}
                      <span className="text-slate-500">
                        (95% CI {feat.ci95_low}–{feat.ci95_high}, n_exp={feat.exposed_observations})
                      </span>
                    </span>
                  </div>
                  <div className="w-full h-2 bg-slate-950 rounded-full overflow-hidden border border-slate-800">
                    <div
                      className="h-full bg-gradient-to-r from-amber-500 to-emerald-400 rounded-full"
                      style={{ width: `${Math.max(4, pct)}%` }}
                    />
                  </div>
                </div>
              );
            })}
          </div>
        </div>

        <div className="lg:col-span-4 bg-slate-900/80 border border-slate-800 rounded-xl p-5 flex flex-col justify-between space-y-4">
          <div>
            <h3 className="text-sm font-semibold text-white mb-1">Collinearity &amp; Sample Diagnostics</h3>
            <p className="text-xs text-slate-400 mb-3">
              Automated checks for correlated co-ingredients (|r| &ge; 0.35) that confound single-feature attribution:
            </p>
            <div className="space-y-2.5">
              {analytics.collinearity_diagnostics.map((pair, idx) => (
                <div key={idx} className="p-3 rounded-lg bg-slate-950 border border-slate-800 text-xs">
                  <div className="flex items-center justify-between font-mono text-amber-300">
                    <span>
                      {pair.feature_a.replace('prior_', '')} ↔ {pair.feature_b.replace('prior_', '')}
                    </span>
                    <span>r = {pair.pearson_r}</span>
                  </div>
                  <p className="text-[11px] text-slate-400 mt-1">{pair.interpretation}</p>
                </div>
              ))}
            </div>
          </div>

          <div className="p-3 rounded-lg bg-slate-950 border border-slate-800 text-xs space-y-1 font-mono">
            <div className="flex justify-between">
              <span className="text-slate-400">Symptom Days (N):</span>
              <span className="text-white">{analytics.sample_summary.total_symptom_observations}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-slate-400">Train / Eval Split:</span>
              <span className="text-white">
                {analytics.sample_summary.train_observations} / {analytics.sample_summary.validation_observations}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-slate-400">Elevated Rate (&ge;7):</span>
              <span className="text-amber-300">
                {Math.round(analytics.sample_summary.elevated_discomfort_prevalence * 100)}%
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function ForecastSvgChart({ series, compact = false }) {
  const width = 820;
  const height = compact ? 210 : 260;
  const pad = { top: 18, right: 20, bottom: 34, left: 36 };
  const plotW = width - pad.left - pad.right;
  const plotH = height - pad.top - pad.bottom;

  const xFor = (i) => pad.left + (i / Math.max(1, series.length - 1)) * plotW;
  const yFor = (val) => pad.top + ((10 - val) / 9) * plotH;

  const upperPoints = series.map((d, i) => `${xFor(i).toFixed(1)},${yFor(d.upper_95_band).toFixed(1)}`);
  const lowerPoints = [...series]
    .reverse()
    .map((d, idx) => {
      const origIdx = series.length - 1 - idx;
      return `${xFor(origIdx).toFixed(1)},${yFor(d.lower_95_band).toFixed(1)}`;
    });
  const areaPolygon = [...upperPoints, ...lowerPoints].join(' ');

  const baselinePath = series
    .map((d, i) => `${i === 0 ? 'M' : 'L'}${xFor(i).toFixed(1)},${yFor(d.expected_baseline).toFixed(1)}`)
    .join(' ');

  const observedPoints = series.filter((d) => d.daily_max_discomfort !== null);
  const observedPath = series
    .map((d, i) =>
      d.daily_max_discomfort !== null
        ? `${i === 0 ? 'M' : 'L'}${xFor(i).toFixed(1)},${yFor(d.daily_max_discomfort).toFixed(1)}`
        : ''
    )
    .filter(Boolean)
    .join(' ');

  return (
    <svg viewBox={`0 0 ${width} ${height}`} className="w-full h-auto overflow-visible" role="img" aria-label="60-day synthetic discomfort time series and baseline band">
      {[2, 4, 6, 8, 10].map((tick) => (
        <g key={tick}>
          <line
            x1={pad.left}
            x2={width - pad.right}
            y1={yFor(tick)}
            y2={yFor(tick)}
            stroke="#1e293b"
            strokeDasharray={tick === 7 ? '4 4' : undefined}
          />
          <text x={pad.left - 8} y={yFor(tick) + 4} textAnchor="end" fontSize="10" fill="#64748b">
            {tick}
          </text>
        </g>
      ))}

      {/* 95% rolling baseline band */}
      <polygon points={areaPolygon} fill="rgba(56, 189, 248, 0.11)" />
      <path d={baselinePath} fill="none" stroke="#38bdf8" strokeWidth="1.75" strokeDasharray="4 3" />
      <path d={observedPath} fill="none" stroke="#f59e0b" strokeWidth="2" />

      {series.map((d, i) => {
        if (d.daily_max_discomfort === null) return null;
        return (
          <g key={d.date}>
            <circle
              cx={xFor(i)}
              cy={yFor(d.daily_max_discomfort)}
              r={d.is_anomaly_spike ? 4.5 : 2.6}
              fill={d.is_anomaly_spike ? '#f43f5e' : '#fbbf24'}
              stroke="#090d16"
              strokeWidth="1"
            />
            {d.polyol_exposures > 0 && (
              <rect
                x={xFor(i) - 2}
                y={height - pad.bottom + 6}
                width="4"
                height="6"
                rx="1"
                fill="#fb7185"
              />
            )}
          </g>
        );
      })}

      {/* X-axis date ticks */}
      {series
        .filter((_, idx) => idx % 10 === 0 || idx === series.length - 1)
        .map((d) => {
          const idx = series.indexOf(d);
          return (
            <text
              key={d.date}
              x={xFor(idx)}
              y={height - 6}
              textAnchor="middle"
              fontSize="10"
              fill="#64748b"
            >
              {d.date.slice(5)}
            </text>
          );
        })}
      {observedPoints.length === 0 && (
        <text x={width / 2} y={height / 2} textAnchor="middle" fill="#94a3b8" fontSize="12">
          No observations
        </text>
      )}
    </svg>
  );
}

function MedallionLineageSection({ medallion, activeLayer, setActiveLayer }) {
  const rows =
    activeLayer === 'bronze'
      ? medallion.bronze.slice(-10).reverse()
      : activeLayer === 'silver'
        ? medallion.silver.slice(-10).reverse()
        : medallion.gold.slice(-10).reverse();

  return (
    <div className="space-y-5">
      <div className="bg-slate-900/80 border border-slate-800 rounded-xl p-5">
        <div className="flex flex-wrap items-center justify-between gap-3 mb-4">
          <div>
            <h2 className="text-base font-semibold text-white">
              dbt / Warehouse Medallion Lineage Inspector
            </h2>
            <p className="text-xs text-slate-400">
              Inspect how operational JSON documents transform into Silver binary flags and Gold strictly-prior 24h/48h lag features.
            </p>
          </div>
          <div className="flex gap-2">
            {[
              { id: 'bronze', label: `Bronze (${medallion.bronze.length})` },
              { id: 'silver', label: `Silver (${medallion.silver.length})` },
              { id: 'gold', label: `Gold Feature Store (${medallion.gold.length})` }
            ].map((l) => (
              <button
                key={l.id}
                onClick={() => setActiveLayer(l.id)}
                className={`px-3 py-1.5 rounded-lg text-xs font-mono border transition-colors ${
                  activeLayer === l.id
                    ? 'bg-amber-500/20 text-amber-300 border-amber-500/50'
                    : 'bg-slate-950 text-slate-400 border-slate-800 hover:text-slate-200'
                }`}
              >
                {l.label}
              </button>
            ))}
          </div>
        </div>

        <div className="overflow-x-auto border border-slate-800 rounded-lg">
          {activeLayer === 'gold' && (
            <table className="w-full text-left text-xs font-mono">
              <thead className="bg-slate-950 text-slate-400 border-b border-slate-800">
                <tr>
                  <th className="p-2.5">event_id</th>
                  <th className="p-2.5">tenant_id</th>
                  <th className="p-2.5">event_timestamp</th>
                  <th className="p-2.5">category</th>
                  <th className="p-2.5">discomfort</th>
                  <th className="p-2.5 text-amber-300">prior_polyol_24h</th>
                  <th className="p-2.5 text-amber-300">prior_gum_24h</th>
                  <th className="p-2.5 text-amber-300">prior_fodmap_48h</th>
                  <th className="p-2.5">prior_stress_24h</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-800/70 bg-slate-900/40">
                {rows.map((r) => (
                  <tr key={r.event_id} className="hover:bg-slate-800/40">
                    <td className="p-2.5 text-slate-300">{r.event_id}</td>
                    <td className="p-2.5 text-emerald-300">{r.tenant_id}</td>
                    <td className="p-2.5 text-slate-400">{r.event_timestamp.slice(0, 16)}Z</td>
                    <td className="p-2.5 uppercase text-slate-200">{r.category}</td>
                    <td className="p-2.5">{r.discomfort_score ?? '—'}</td>
                    <td className="p-2.5 text-amber-300 font-semibold">{r.prior_polyol_24h}</td>
                    <td className="p-2.5 text-amber-300">{r.prior_gum_24h}</td>
                    <td className="p-2.5 text-amber-300">{r.prior_fodmap_48h}</td>
                    <td className="p-2.5">{r.prior_elevated_stress_24h}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}

          {activeLayer === 'silver' && (
            <table className="w-full text-left text-xs font-mono">
              <thead className="bg-slate-950 text-slate-400 border-b border-slate-800">
                <tr>
                  <th className="p-2.5">event_id</th>
                  <th className="p-2.5">event_date_utc</th>
                  <th className="p-2.5">category</th>
                  <th className="p-2.5">has_polyol</th>
                  <th className="p-2.5">has_gum</th>
                  <th className="p-2.5">has_emulsifier</th>
                  <th className="p-2.5">unverified_gf</th>
                  <th className="p-2.5">is_raw_prep</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-800/70 bg-slate-900/40">
                {rows.map((r) => (
                  <tr key={r.event_id}>
                    <td className="p-2.5 text-slate-300">{r.event_id}</td>
                    <td className="p-2.5 text-slate-400">{r.event_date_utc}</td>
                    <td className="p-2.5 uppercase">{r.category}</td>
                    <td className="p-2.5 text-rose-300">{r.has_high_fodmap_polyol}</td>
                    <td className="p-2.5 text-amber-300">{r.has_hydrocolloid_gum}</td>
                    <td className="p-2.5 text-purple-300">{r.has_emulsifier_irritant}</td>
                    <td className="p-2.5">{r.has_unverified_gluten_risk}</td>
                    <td className="p-2.5">{r.is_raw_plant_prep}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}

          {activeLayer === 'bronze' && (
            <table className="w-full text-left text-xs font-mono">
              <thead className="bg-slate-950 text-slate-400 border-b border-slate-800">
                <tr>
                  <th className="p-2.5">document_id</th>
                  <th className="p-2.5">tenant_id</th>
                  <th className="p-2.5">event_timestamp</th>
                  <th className="p-2.5">raw_payload_json (truncated preview)</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-800/70 bg-slate-900/40">
                {rows.map((r) => (
                  <tr key={r.document_id}>
                    <td className="p-2.5 text-slate-300">{r.document_id}</td>
                    <td className="p-2.5 text-emerald-300">{r.tenant_id}</td>
                    <td className="p-2.5 text-slate-400">{r.event_timestamp}</td>
                    <td className="p-2.5 text-slate-400 max-w-md truncate">{r.raw_payload_json}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </div>
  );
}
