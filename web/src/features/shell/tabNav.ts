/**
 * Tab 切换桥(主会话维护)。
 * 用途:功能屏(如通讯录)需要"创建会话后跳到聊天 Tab"时调用 goTab('chats')。
 * MobileApp 挂载时通过 registerTabSetter 注册真正的 setter。
 */
export type TabKey = 'chats' | 'contacts' | 'discover' | 'me';

let setter: ((t: TabKey) => void) | null = null;

export function registerTabSetter(fn: ((t: TabKey) => void) | null): void {
  setter = fn;
}

export function goTab(tab: TabKey): void {
  setter?.(tab);
}
