/**
 * 消息长按操作菜单(底部弹出):复制 / 收藏 / 转发 / 删除 / 取消。
 * 复制走 navigator.clipboard,失败降级到 prompt 让用户手动复制。
 * 收藏/转发/删除的具体逻辑由主会话接线时通过回调注入,这里只负责触发 + 关闭。
 */
export default function MessageActionSheet({
  open,
  msg,
  onClose,
  onForward,
  onStar,
  onDelete,
}: {
  open: boolean;
  msg: { id: string; text: string; kind: string } | null;
  onClose: () => void;
  onForward: () => void;
  onStar: () => void;
  onDelete: () => void;
}) {
  const copy = async () => {
    const text = msg?.text || '';
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      window.prompt('复制失败,请手动复制:', text);
    }
    onClose();
  };

  if (!open || !msg) return null;

  const actions = [
    { label: '复制', icon: '📋', run: copy },
    { label: '收藏', icon: '⭐', run: () => { onStar(); onClose(); } },
    { label: '转发', icon: '↗️', run: () => { onForward(); onClose(); } },
    { label: '删除', icon: '🗑', danger: true, run: () => { onDelete(); onClose(); } },
  ];

  return (
    <div className="mv-sheet" onClick={onClose}>
      <div className="mv-sheet-panel" onClick={(e) => e.stopPropagation()}>
        {msg.text && (
          <div className="mv-sheet-msg">
            {msg.text.length > 80 ? `${msg.text.slice(0, 80)}…` : msg.text}
          </div>
        )}
        {actions.map((a) => (
          <button
            key={a.label}
            className={`mv-sheet-action${a.danger ? ' mv-sheet-action-danger' : ''}`}
            onClick={a.run}
          >
            <span className="mv-sheet-action-icon">{a.icon}</span>
            <span>{a.label}</span>
          </button>
        ))}
        <button className="mv-sheet-action mv-sheet-cancel" onClick={onClose}>
          取消
        </button>
      </div>
    </div>
  );
}
