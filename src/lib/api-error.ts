/** 业务错误：路由层统一转成 {error} + HTTP status（记单服务/AI 落单共用） */
export class ApiError extends Error {
  constructor(
    message: string,
    public readonly status = 400,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}
