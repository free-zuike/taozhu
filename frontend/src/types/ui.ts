/** 共享 UI 类型 */

/** 拍照识别导入的一行（已匹配系统商品 + 确认价） */
export interface ImportedRow {
  name: string;
  itemId: string;
  priceId: string;
  unit: string;
  quantity: number;
  price: number;
}