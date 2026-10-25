import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    // Loopback by default: the API is local-only unless HOST is set, so
    // exposing the UI on the LAN would give a broken page to other machines.
    host: process.env.HOST || "127.0.0.1",
    cors: true,
    open: false,
    port: 3000,
    proxy: {
      // 127.0.0.1 instead of localhost: the API binds loopback only, and
      // "localhost" may resolve to ::1 first on Windows.
      "/api": {
        target: "http://127.0.0.1:8484",
        changeOrigin: true,
      },
      "/proxy": {
        target: "http://127.0.0.1:8484",
        changeOrigin: true,
      },
    },
  },
  resolve: {
    alias: {
      src: "/src",
    },
  },
  define: {
    global: {},
  },
});
