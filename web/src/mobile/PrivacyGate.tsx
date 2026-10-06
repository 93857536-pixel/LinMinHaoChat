import { useEffect, useState, type ReactNode } from 'react';

/**
 * 隐私模式:App 切到后台/窗口失焦时给内容加模糊遮罩(对应 iOS PrivacyMode/PrivacyBlurView)。
 * 纯 CSS 实现,无第三方依赖。
 */
export default function PrivacyGate({ children }: { children: ReactNode }) {
  const [hidden, setHidden] = useState(false);

  useEffect(() => {
    const onVis = () => setHidden(document.visibilityState === 'hidden');
    const onBlur = () => setHidden(true);
    const onFocus = () => setHidden(document.visibilityState === 'hidden');
    document.addEventListener('visibilitychange', onVis);
    window.addEventListener('blur', onBlur);
    window.addEventListener('focus', onFocus);
    return () => {
      document.removeEventListener('visibilitychange', onVis);
      window.removeEventListener('blur', onBlur);
      window.removeEventListener('focus', onFocus);
    };
  }, []);

  return (
    <div className={hidden ? 'mv-privacy-on' : undefined}>
      {children}
      {hidden && <div className="mv-privacy-mask" aria-hidden="true" />}
    </div>
  );
}
