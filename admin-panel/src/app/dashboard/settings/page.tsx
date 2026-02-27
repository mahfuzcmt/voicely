'use client';

import { useState } from 'react';
import toast from 'react-hot-toast';
import { Trash2, RefreshCw, Clock, HardDrive, AlertTriangle, Database } from 'lucide-react';

export default function SettingsPage() {
  const [cleanupLoading, setCleanupLoading] = useState(false);
  const [cleanupResult, setCleanupResult] = useState<{
    deletedFiles: number;
    deletedMessages: number;
    deletedLogs: number;
    errors: number;
  } | null>(null);

  const [backfillLoading, setBackfillLoading] = useState(false);
  const [backfillResult, setBackfillResult] = useState<{
    totalMessages: number;
    processed: number;
    errors: number;
  } | null>(null);

  const handleBackfill = async () => {
    if (!confirm('This will populate usage stats from existing messages. Continue?')) {
      return;
    }

    setBackfillLoading(true);
    setBackfillResult(null);

    try {
      const res = await fetch('/api/stats/backfill', {
        method: 'POST',
      });

      const data = await res.json();

      if (!res.ok) {
        throw new Error(data.error || 'Backfill failed');
      }

      setBackfillResult({
        totalMessages: data.totalMessages,
        processed: data.processed,
        errors: data.errors,
      });

      toast.success(data.message);
    } catch (error) {
      toast.error('Backfill failed: ' + (error as Error).message);
    } finally {
      setBackfillLoading(false);
    }
  };

  const handleCleanup = async () => {
    if (!confirm('Are you sure you want to run audio cleanup? This will delete audio files older than 7 days.')) {
      return;
    }

    setCleanupLoading(true);
    setCleanupResult(null);

    try {
      const res = await fetch('/api/cleanup', {
        method: 'DELETE',
      });

      const data = await res.json();

      if (!res.ok) {
        throw new Error(data.error || 'Cleanup failed');
      }

      setCleanupResult({
        deletedFiles: data.deletedFiles,
        deletedMessages: data.deletedMessages,
        deletedLogs: data.deletedLogs,
        errors: data.errors,
      });

      toast.success(data.message);
    } catch (error) {
      toast.error('Cleanup failed: ' + (error as Error).message);
    } finally {
      setCleanupLoading(false);
    }
  };

  return (
    <div>
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-gray-900">Settings</h1>
        <p className="text-gray-500 mt-1">Manage system settings and maintenance</p>
      </div>

      {/* Backfill Stats Section */}
      <div className="card mb-6">
        <div className="flex items-start gap-4">
          <div className="p-3 bg-blue-100 rounded-lg">
            <Database className="w-6 h-6 text-blue-600" />
          </div>
          <div className="flex-1">
            <h2 className="text-lg font-semibold text-gray-900">Backfill Usage Stats</h2>
            <p className="text-gray-500 mt-1">
              Populate usage statistics from existing voice messages in the database.
            </p>

            <div className="mt-4 p-4 bg-gray-50 rounded-lg">
              <p className="text-sm text-gray-600">
                Run this once to generate usage reports from historical messages.
                New messages will automatically be tracked going forward.
              </p>
            </div>

            {backfillResult && (
              <div className="mt-4 p-4 bg-green-50 border border-green-200 rounded-lg">
                <h3 className="font-medium text-green-800 mb-2">Backfill Complete</h3>
                <ul className="space-y-1 text-sm text-green-700">
                  <li>Total messages found: {backfillResult.totalMessages}</li>
                  <li>Successfully processed: {backfillResult.processed}</li>
                  {backfillResult.errors > 0 && (
                    <li className="text-orange-600">Errors: {backfillResult.errors}</li>
                  )}
                </ul>
              </div>
            )}

            <div className="mt-4">
              <button
                onClick={handleBackfill}
                disabled={backfillLoading}
                className="btn btn-primary flex items-center gap-2"
              >
                {backfillLoading ? (
                  <>
                    <RefreshCw className="w-4 h-4 animate-spin" />
                    Processing Messages...
                  </>
                ) : (
                  <>
                    <Database className="w-4 h-4" />
                    Backfill Stats Now
                  </>
                )}
              </button>
            </div>
          </div>
        </div>
      </div>

      {/* Storage Cleanup Section */}
      <div className="card mb-6">
        <div className="flex items-start gap-4">
          <div className="p-3 bg-red-100 rounded-lg">
            <Trash2 className="w-6 h-6 text-red-600" />
          </div>
          <div className="flex-1">
            <h2 className="text-lg font-semibold text-gray-900">Audio Cleanup</h2>
            <p className="text-gray-500 mt-1">
              Delete old audio files and messages to free up storage space.
            </p>

            <div className="mt-4 p-4 bg-gray-50 rounded-lg">
              <h3 className="font-medium text-gray-700 mb-2">Retention Policy</h3>
              <ul className="space-y-2 text-sm text-gray-600">
                <li className="flex items-center gap-2">
                  <Clock className="w-4 h-4" />
                  Audio files: <strong>7 days</strong>
                </li>
                <li className="flex items-center gap-2">
                  <HardDrive className="w-4 h-4" />
                  Usage logs: <strong>30 days</strong>
                </li>
              </ul>
            </div>

            {cleanupResult && (
              <div className="mt-4 p-4 bg-green-50 border border-green-200 rounded-lg">
                <h3 className="font-medium text-green-800 mb-2">Cleanup Complete</h3>
                <ul className="space-y-1 text-sm text-green-700">
                  <li>Files deleted: {cleanupResult.deletedFiles}</li>
                  <li>Messages deleted: {cleanupResult.deletedMessages}</li>
                  <li>Logs deleted: {cleanupResult.deletedLogs}</li>
                  {cleanupResult.errors > 0 && (
                    <li className="text-orange-600">Errors: {cleanupResult.errors}</li>
                  )}
                </ul>
              </div>
            )}

            <div className="mt-4 flex items-center gap-4">
              <button
                onClick={handleCleanup}
                disabled={cleanupLoading}
                className="btn btn-primary flex items-center gap-2"
              >
                {cleanupLoading ? (
                  <>
                    <RefreshCw className="w-4 h-4 animate-spin" />
                    Running Cleanup...
                  </>
                ) : (
                  <>
                    <Trash2 className="w-4 h-4" />
                    Run Cleanup Now
                  </>
                )}
              </button>
            </div>
          </div>
        </div>
      </div>

      {/* Automated Cleanup Info */}
      <div className="card">
        <div className="flex items-start gap-4">
          <div className="p-3 bg-blue-100 rounded-lg">
            <Clock className="w-6 h-6 text-blue-600" />
          </div>
          <div className="flex-1">
            <h2 className="text-lg font-semibold text-gray-900">Automated Cleanup</h2>
            <p className="text-gray-500 mt-1">
              Set up automated daily cleanup using a cron job service.
            </p>

            <div className="mt-4 p-4 bg-gray-50 rounded-lg">
              <h3 className="font-medium text-gray-700 mb-2">Cron Setup Instructions</h3>
              <ol className="space-y-3 text-sm text-gray-600 list-decimal list-inside">
                <li>
                  Add <code className="bg-gray-200 px-1 rounded">CLEANUP_SECRET</code> to your environment variables
                </li>
                <li>
                  Use a cron service (cron-job.org, Vercel Cron, or server crontab)
                </li>
                <li>
                  Schedule a daily DELETE request:
                  <pre className="mt-2 p-2 bg-gray-800 text-green-400 rounded text-xs overflow-x-auto">
{`# Daily at 3 AM
curl -X DELETE https://your-domain.com/api/cleanup \\
  -H "x-cleanup-secret: YOUR_SECRET"`}
                  </pre>
                </li>
              </ol>
            </div>

            <div className="mt-4 p-4 bg-yellow-50 border border-yellow-200 rounded-lg flex items-start gap-2">
              <AlertTriangle className="w-5 h-5 text-yellow-600 flex-shrink-0 mt-0.5" />
              <p className="text-sm text-yellow-700">
                Make sure to set a strong <code className="bg-yellow-100 px-1 rounded">CLEANUP_SECRET</code>
                in production to prevent unauthorized cleanup requests.
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
