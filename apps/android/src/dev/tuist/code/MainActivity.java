package dev.tuist.code;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.PorterDuff;
import android.net.Uri;
import android.os.Bundle;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.KeyStore;
import java.util.Base64;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;

public final class MainActivity extends Activity {
    private static final String DEFAULT_ORIGIN = "https://tuist.dev";
    private static final String DEFAULT_CLIENT_ID = "b3298a92-3deb-4f5e-a526-b7ad324979b5";
    private static final String CALLBACK_SCHEME = "tuist";
    private static final String REDIRECT_URI = "tuist://oauth-callback";
    private static final String TOKEN_KEY_ALIAS = "dev.tuist.code.authentication";
    private static final int STATE_SIGNED_OUT = 0;
    private static final int STATE_AUTHENTICATING = 1;
    private static final int STATE_AUTHENTICATED = 2;
    private static final int EVENT_RESTORE_UNAUTHENTICATED = 0;
    private static final int EVENT_RESTORE_AUTHENTICATED = 1;
    private static final int EVENT_START_SIGN_IN = 2;
    private static final int EVENT_SIGN_IN_SUCCEEDED = 3;
    private static final int EVENT_SIGN_IN_FAILED = 4;
    private static final int EVENT_CANCELLED = 5;
    private static final int EVENT_SIGN_OUT = 6;

    static {
        System.loadLibrary("tuist_code_shared");
    }

    private static native int brandColor();
    private static native int authenticationStateAfter(int state, int event);

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private SharedPreferences preferences;
    private String origin;
    private String clientId;
    private LinearLayout content;
    private int authenticationState = STATE_SIGNED_OUT;
    private boolean awaitingAuthorizationResult;
    private String errorMessage;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        preferences = getSharedPreferences("tuist-code-authentication", MODE_PRIVATE);
        configureAuthentication(getIntent());
        transition(isAuthenticated() ? EVENT_RESTORE_AUTHENTICATED : EVENT_RESTORE_UNAUTHENTICATED);
        render();
        handleOAuthCallback(getIntent() == null ? null : getIntent().getData());
    }

    @Override
    public void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        configureAuthentication(intent);
        transition(isAuthenticated() ? EVENT_RESTORE_AUTHENTICATED : EVENT_RESTORE_UNAUTHENTICATED);
        handleOAuthCallback(intent.getData());
    }

    @Override
    public void onResume() {
        super.onResume();
        if (awaitingAuthorizationResult && authenticationState == STATE_AUTHENTICATING) {
            awaitingAuthorizationResult = false;
            preferences.edit().remove("pending_state").remove("pending_verifier").apply();
            transition(EVENT_CANCELLED);
            render();
        }
    }

    @Override
    protected void onDestroy() {
        executor.shutdownNow();
        super.onDestroy();
    }

    private void configureAuthentication(Intent intent) {
        String requestedOrigin = intent == null ? null : normalizeOrigin(intent.getStringExtra("tuist_origin"));
        String requestedClientId = intent == null ? null : nonEmpty(intent.getStringExtra("tuist_oauth_client_id"));

        if (requestedOrigin != null) {
            SharedPreferences.Editor editor = preferences.edit().putString("origin", requestedOrigin);
            if (requestedClientId == null) {
                editor.remove("client_id");
            }
            editor.apply();
        }
        if (requestedClientId != null) {
            preferences.edit().putString("client_id", requestedClientId).apply();
        }

        origin = preferences.getString("origin", DEFAULT_ORIGIN);
        clientId = preferences.getString("client_id", defaultClientIdFor(origin));
    }

    private void render() {
        int sharedBrandColor = brandColor();
        int tint = Color.rgb(
                (sharedBrandColor >> 16) & 0xFF,
                (sharedBrandColor >> 8) & 0xFF,
                sharedBrandColor & 0xFF
        );

        content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setGravity(Gravity.CENTER);
        content.setPadding(dp(32), dp(32), dp(32), dp(32));
        content.setBackgroundColor(Color.rgb(23, 23, 23));

        ImageView logo = new ImageView(this);
        logo.setImageResource(R.drawable.tuist_logo);
        logo.setColorFilter(tint, PorterDuff.Mode.SRC_IN);
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

        if (authenticationState == STATE_AUTHENTICATED) {
            addMessage("Signed in to " + origin, Color.rgb(190, 190, 190), 16);
            addButton("Sign out", view -> {
                clearTokens();
                errorMessage = null;
                transition(EVENT_SIGN_OUT);
                render();
            }, tint);
        } else if (authenticationState == STATE_AUTHENTICATING) {
            addMessage("Waiting for sign in", Color.WHITE, 16);
        } else {
            addMessage("Sign in to access your projects and collaborate with your team", Color.rgb(190, 190, 190), 16);
            addButton("Sign in with Tuist", view -> startOAuthFlow(), tint);

            if (errorMessage != null) {
                addMessage(errorMessage, Color.rgb(255, 125, 125), 14);
            }
        }

        setContentView(content);
    }

    private void addMessage(String message, int color, int textSize) {
        TextView messageView = new TextView(this);
        messageView.setText(message);
        messageView.setTextColor(color);
        messageView.setTextSize(TypedValue.COMPLEX_UNIT_SP, textSize);
        messageView.setGravity(Gravity.CENTER);
        messageView.setMaxWidth(dp(360));
        LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
        );
        layout.topMargin = dp(16);
        content.addView(messageView, layout);
    }

    private void addButton(String label, View.OnClickListener listener, int tint) {
        Button button = new Button(this);
        button.setText(label);
        button.setAllCaps(false);
        button.setTextColor(Color.WHITE);
        button.setBackgroundColor(tint);
        button.setOnClickListener(listener);
        LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
        );
        layout.topMargin = dp(20);
        content.addView(button, layout);
    }

    private void startOAuthFlow() {
        String verifier = codeVerifier();
        String state = UUID.randomUUID().toString();
        preferences.edit()
                .putString("pending_verifier", verifier)
                .putString("pending_state", state)
                .apply();
        errorMessage = null;
        transition(EVENT_START_SIGN_IN);
        render();

        Uri authorizationUri = Uri.parse(origin).buildUpon()
                .appendPath("oauth2")
                .appendPath("authorize")
                .appendQueryParameter("response_type", "code")
                .appendQueryParameter("client_id", clientId)
                .appendQueryParameter("redirect_uri", REDIRECT_URI)
                .appendQueryParameter("state", state)
                .appendQueryParameter("code_challenge", codeChallenge(verifier))
                .appendQueryParameter("code_challenge_method", "S256")
                .build();

        try {
            startActivity(new Intent(Intent.ACTION_VIEW, authorizationUri));
            awaitingAuthorizationResult = true;
        } catch (Exception exception) {
            fail("Tuist could not open a browser for sign in.");
            render();
        }
    }

    private void handleOAuthCallback(Uri callback) {
        if (callback == null
                || !CALLBACK_SCHEME.equals(callback.getScheme())
                || !"oauth-callback".equals(callback.getHost())) {
            return;
        }

        awaitingAuthorizationResult = false;

        String expectedState = preferences.getString("pending_state", null);
        String returnedState = callback.getQueryParameter("state");
        String code = callback.getQueryParameter("code");
        String verifier = preferences.getString("pending_verifier", null);
        preferences.edit().remove("pending_state").remove("pending_verifier").apply();

        if (expectedState == null || !expectedState.equals(returnedState) || code == null || verifier == null) {
            fail("Tuist returned an invalid sign-in response.");
            render();
            return;
        }

        transition(EVENT_START_SIGN_IN);
        render();
        exchangeAuthorizationCode(code, verifier);
    }

    private void exchangeAuthorizationCode(String code, String verifier) {
        executor.execute(() -> {
            try {
                HttpURLConnection connection = (HttpURLConnection) new URL(origin + "/oauth2/token").openConnection();
                connection.setRequestMethod("POST");
                connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
                connection.setDoOutput(true);

                String body = "grant_type=authorization_code"
                        + "&code=" + Uri.encode(code)
                        + "&redirect_uri=" + Uri.encode(REDIRECT_URI)
                        + "&client_id=" + Uri.encode(clientId)
                        + "&code_verifier=" + Uri.encode(verifier);
                connection.getOutputStream().write(body.getBytes(StandardCharsets.UTF_8));

                int status = connection.getResponseCode();
                String response = readResponse(status < 400 ? connection.getInputStream() : connection.getErrorStream());
                connection.disconnect();
                if (status != HttpURLConnection.HTTP_OK) {
                    throw new IllegalStateException("The server rejected the authorization code.");
                }

                JSONObject tokens = new JSONObject(response);
                String accessToken = tokens.getString("access_token");
                String refreshToken = tokens.getString("refresh_token");
                preferences.edit()
                        .putString(accessTokenKey(), encrypt(accessToken))
                        .putString(refreshTokenKey(), encrypt(refreshToken))
                        .apply();

                runOnUiThread(() -> {
                    errorMessage = null;
                    transition(EVENT_SIGN_IN_SUCCEEDED);
                    render();
                });
            } catch (Exception exception) {
                runOnUiThread(() -> {
                    fail("Tuist could not complete sign in. " + exception.getMessage());
                    render();
                });
            }
        });
    }

    private boolean isAuthenticated() {
        return decrypt(preferences.getString(accessTokenKey(), null)) != null;
    }

    private void clearTokens() {
        preferences.edit()
                .remove(accessTokenKey())
                .remove(refreshTokenKey())
                .apply();
    }

    private void fail(String message) {
        errorMessage = message;
        transition(EVENT_SIGN_IN_FAILED);
    }

    private void transition(int event) {
        authenticationState = authenticationStateAfter(authenticationState, event);
    }

    private String accessTokenKey() {
        return "access_token." + origin;
    }

    private String refreshTokenKey() {
        return "refresh_token." + origin;
    }

    private static String codeVerifier() {
        byte[] bytes = new byte[32];
        new SecureRandom().nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    private static String codeChallenge(String verifier) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(verifier.getBytes(StandardCharsets.UTF_8));
            return Base64.getUrlEncoder().withoutPadding().encodeToString(digest);
        } catch (Exception exception) {
            throw new IllegalStateException("The device cannot create a sign-in challenge.", exception);
        }
    }

    private static String readResponse(InputStream stream) throws Exception {
        if (stream == null) {
            return "";
        }

        BufferedReader reader = new BufferedReader(new InputStreamReader(stream, StandardCharsets.UTF_8));
        StringBuilder response = new StringBuilder();
        String line;
        while ((line = reader.readLine()) != null) {
            response.append(line);
        }
        reader.close();
        return response.toString();
    }

    private static String encrypt(String value) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, tokenEncryptionKey());
        String initializationVector = Base64.getUrlEncoder().withoutPadding().encodeToString(cipher.getIV());
        String encryptedValue = Base64.getUrlEncoder().withoutPadding().encodeToString(
                cipher.doFinal(value.getBytes(StandardCharsets.UTF_8))
        );
        return initializationVector + "." + encryptedValue;
    }

    private static String decrypt(String value) {
        if (value == null) {
            return null;
        }

        try {
            String[] parts = value.split("\\.", 2);
            if (parts.length != 2) {
                return null;
            }
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(
                    Cipher.DECRYPT_MODE,
                    tokenEncryptionKey(),
                    new javax.crypto.spec.GCMParameterSpec(128, Base64.getUrlDecoder().decode(parts[0]))
            );
            return new String(cipher.doFinal(Base64.getUrlDecoder().decode(parts[1])), StandardCharsets.UTF_8);
        } catch (Exception exception) {
            return null;
        }
    }

    private static SecretKey tokenEncryptionKey() throws Exception {
        KeyStore keyStore = KeyStore.getInstance("AndroidKeyStore");
        keyStore.load(null);
        if (keyStore.containsAlias(TOKEN_KEY_ALIAS)) {
            return ((KeyStore.SecretKeyEntry) keyStore.getEntry(TOKEN_KEY_ALIAS, null)).getSecretKey();
        }

        KeyGenerator keyGenerator = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES,
                "AndroidKeyStore"
        );
        keyGenerator.init(new KeyGenParameterSpec.Builder(
                TOKEN_KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT
        )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build());
        return keyGenerator.generateKey();
    }

    private static String normalizeOrigin(String value) {
        if (value == null) {
            return null;
        }
        Uri uri = Uri.parse(value);
        if (uri.getHost() == null
                || uri.getUserInfo() != null
                || !("https".equals(uri.getScheme()) || "http".equals(uri.getScheme()))) {
            return null;
        }
        return uri.buildUpon().path(null).query(null).fragment(null).build().toString().replaceAll("/$", "");
    }

    private static String nonEmpty(String value) {
        return value == null || value.isEmpty() ? null : value;
    }

    private static String defaultClientIdFor(String origin) {
        if ("https://staging.tuist.dev".equals(origin)) {
            return "bcb85209-0cef-4acd-8dd4-e0d1c5e5e09a";
        }
        if ("https://canary.tuist.dev".equals(origin)) {
            return "ca49d1d6-acaf-4eaa-b866-774b799044db";
        }
        if ("http://localhost:8080".equals(origin)) {
            return "5339abf2-467c-4690-b816-17246ed149d2";
        }
        return DEFAULT_CLIENT_ID;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
