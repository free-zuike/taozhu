/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** Android App 构建时指向生产域名（Web 同源为空） */
  readonly VITE_API_BASE?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}