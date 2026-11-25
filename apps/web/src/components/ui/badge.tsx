import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

const badgeVariants = cva(
  "inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-heading transition-colors",
  {
    variants: {
      variant: {
        default: "border-main/25 bg-main/10 text-main",
        neutral: "border-border bg-bw text-text/80",
        success:
          "border-emerald-500/25 bg-emerald-500/10 text-emerald-600 dark:text-emerald-400",
        danger: "border-rose-500/25 bg-rose-500/10 text-rose-600 dark:text-rose-400",
        warning: "border-amber-500/25 bg-amber-500/10 text-amber-600 dark:text-amber-400",
        info: "border-sky-500/25 bg-sky-500/10 text-sky-600 dark:text-sky-400",
      },
    },
    defaultVariants: {
      variant: "default",
    },
  },
);

export interface BadgeProps
  extends React.HTMLAttributes<HTMLDivElement>,
    VariantProps<typeof badgeVariants> {}

function Badge({ className, variant, ...props }: BadgeProps) {
  return <div className={cn(badgeVariants({ variant }), className)} {...props} />;
}

export { Badge, badgeVariants };
