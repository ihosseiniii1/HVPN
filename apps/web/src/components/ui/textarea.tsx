import * as React from "react";
import { cn } from "@/lib/utils";

const Textarea = React.forwardRef<
  HTMLTextAreaElement,
  React.TextareaHTMLAttributes<HTMLTextAreaElement>
>(({ className, ...props }, ref) => (
  <textarea
    ref={ref}
    className={cn(
      "flex min-h-[80px] w-full rounded-base border border-border bg-bw px-3 py-2 text-sm font-base text-text shadow-soft transition-colors placeholder:text-text/45 hover:border-borderStrong focus-visible:border-main focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-main/10 disabled:cursor-not-allowed disabled:opacity-50",
      className,
    )}
    {...props}
  />
));
Textarea.displayName = "Textarea";

export { Textarea };
