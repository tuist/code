package dev.tuist.code;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.PorterDuff;
import android.os.Bundle;
import android.util.TypedValue;
import android.view.Gravity;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

public final class MainActivity extends Activity {
    static {
        System.loadLibrary("tuist_code_shared");
    }

    private static native int brandColor();

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        int sharedBrandColor = brandColor();
        int brandColor = Color.rgb(
                (sharedBrandColor >> 16) & 0xFF,
                (sharedBrandColor >> 8) & 0xFF,
                sharedBrandColor & 0xFF
        );
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setGravity(Gravity.CENTER);
        content.setBackgroundColor(Color.rgb(23, 23, 23));

        ImageView logo = new ImageView(this);
        logo.setImageResource(R.drawable.tuist_logo);
        logo.setColorFilter(brandColor, PorterDuff.Mode.SRC_IN);
        content.addView(logo, new LinearLayout.LayoutParams(dp(80), dp(80)));

        TextView title = new TextView(this);
        title.setText(R.string.app_name);
        title.setTextColor(Color.WHITE);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 24);
        title.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams titleLayout = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
        );
        titleLayout.topMargin = dp(20);
        content.addView(title, titleLayout);

        setContentView(content);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
