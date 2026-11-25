import * as React from "react";
import { cn } from "@/lib/utils";

const Input = React.forwardRef<HTMLInputElement, React.InputHTMLAttributes<HTMLInputElement>>(
  ({ className, type, ...props }, ref) => (
    <input
      type={type}
      ref={ref}
      className={cn(
        "flex h-10 w-full rounded-base border border-border bg-bw px-3 py-2 text-sm font-base text-text shadow-soft transition-colors file:border-0 file:bg-transparent file:text-sm file:font-heading file:text-main placeholder:text-text/45 hover:border-borderStrong focus-visible:border-main focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-main/10 disabled:cursor-not-allowed disabled:opacity-50",
        className,
      )}
      {...props}
    />
  ),
);
Input.displayName = "Input";

export { Input };
