import { initializeApp } from 'firebase-admin/app';
import { defineString } from 'firebase-functions/params';

// Shared ESM module evaluates once when both function entrypoints are loaded.
initializeApp();

export const allowedOrigins = defineString('LIVE_ALLOWED_ORIGINS', {
  default: 'https://devfest-flutter-a59e8.web.app,https://devfest-flutter-a59e8.firebaseapp.com',
});
