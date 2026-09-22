package com.osasuwu.like_spotify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity(), EventChannel.StreamHandler {
	private var eventSink: EventChannel.EventSink? = null
	private var localReceiver: BroadcastReceiver? = null

	companion object {
		@Volatile
		@JvmStatic
		var isFlutterAttached: Boolean = false
			private set

		/** Session confirm (~2 s) + worst-case token, search, rate and extra-action calls. */
		private const val YTM_LIKE_WAKE_LOCK_MS = 60_000L

		/**
		 * Off-main-thread runner for YouTube Music likes. Process-wide (not per
		 * activity) so a like in flight survives an activity recreate.
		 */
		private val ytmLikeExecutor: ExecutorService = Executors.newSingleThreadExecutor()
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger,
			AppConstants.CHANNEL_SERVICE
		).setMethodCallHandler { call, result ->
			when (call.method) {
				"startService" -> {
					// false = the system refused the start; the Dart side re-reads
					// `isServiceEnabled`, which now answers honestly.
					result.success(startListenerService())
				}

				"stopService" -> {
					stopListenerService()
					result.success(true)
				}

				"isServiceEnabled" -> {
					val enabled = prefs().getBoolean(AppConstants.KEY_SERVICE_ENABLED, false)
					result.success(enabled)
				}

				"setTriggerConfig" -> {
					val pattern = call.argument<String>("pattern") ?: "pause,play"
					val window = call.argument<Int>("windowMs")?.toLong() ?: 1000L
					val debounce = call.argument<Int>("debounceMs")?.toLong() ?: 650L
					val volume = call.argument<Int>("feedbackVolume") ?: AppConstants.DEFAULT_FEEDBACK_VOLUME
					prefs().edit()
						.putString(AppConstants.KEY_PATTERN, pattern)
						.putLong(AppConstants.KEY_WINDOW_MS, window)
						.putLong(AppConstants.KEY_DEBOUNCE_MS, debounce)
						.putInt(AppConstants.KEY_FEEDBACK_VOLUME, volume)
						.apply()
					result.success(true)
				}

				"syncSpotifyTokens" -> {
					val accessToken = call.argument<String>("accessToken")
					val refreshToken = call.argument<String>("refreshToken")
					val expiresAt = call.argument<Int>("expiresAtEpochSec")?.toLong() ?: 0L
					val clientId = call.argument<String>("clientId")

					prefs().edit()
						.putString(AppConstants.KEY_SPOTIFY_ACCESS_TOKEN, accessToken)
						.putString(AppConstants.KEY_SPOTIFY_REFRESH_TOKEN, refreshToken)
						.putLong(AppConstants.KEY_SPOTIFY_EXPIRES_AT, expiresAt)
						.putString(AppConstants.KEY_SPOTIFY_CLIENT_ID, clientId)
						.apply()
					result.success(true)
				}

				"clearSpotifyUserId" -> {
					// The id is cached here with no expiry and keys the shared
					// like counter's rows, so an account change has to drop it
					// or the new account's likes land on the old account's row.
					prefs().edit()
						.remove(AppConstants.KEY_SPOTIFY_USER_ID)
						.apply()
					result.success(true)
				}

				"syncYouTubeMusicTokens" -> {
					// Epoch ms exceeds Int range, so the channel delivers a Long;
					// read it as Number to accept either.
					val expiresAt = call.argument<Number>("expiresAtEpochMs")?.toLong() ?: 0L
					val editor = prefs().edit()
						.putString(AppConstants.KEY_YTM_ACCESS_TOKEN, call.argument<String>("accessToken"))
						.putString(AppConstants.KEY_YTM_REFRESH_TOKEN, call.argument<String>("refreshToken"))
						.putLong(AppConstants.KEY_YTM_TOKEN_EXPIRES_AT, expiresAt)
						.putString(AppConstants.KEY_YTM_CLIENT_ID, call.argument<String>("clientId"))
						.putString(AppConstants.KEY_YTM_CLIENT_SECRET, call.argument<String>("clientSecret"))
					val userSub = call.argument<String>("userSub")
					if (userSub.isNullOrEmpty()) {
						editor.remove(AppConstants.KEY_YTM_USER_SUB)
					} else {
						editor.putString(AppConstants.KEY_YTM_USER_SUB, userSub)
					}
					editor.apply()
					result.success(true)
				}

				"clearYouTubeMusicTokens" -> {
					prefs().edit()
						.remove(AppConstants.KEY_YTM_ACCESS_TOKEN)
						.remove(AppConstants.KEY_YTM_REFRESH_TOKEN)
						.remove(AppConstants.KEY_YTM_TOKEN_EXPIRES_AT)
						.remove(AppConstants.KEY_YTM_CLIENT_ID)
						.remove(AppConstants.KEY_YTM_CLIENT_SECRET)
						.remove(AppConstants.KEY_YTM_USER_SUB)
						.apply()
					result.success(true)
				}

				"isIgnoringBatteryOptimizations" -> {
					val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
					result.success(powerManager.isIgnoringBatteryOptimizations(packageName))
				}

				"openIgnoreBatteryOptimizationsSettings" -> {
					val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
						data = Uri.parse("package:$packageName")
					}
					safeStart(intent)
					result.success(true)
				}

				"openBatteryOptimizationSettings" -> {
					safeStart(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
					result.success(true)
				}

				"openNotificationSettings" -> {
					if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
						val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
							putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
						}
						safeStart(intent)
					} else {
						val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
							data = Uri.parse("package:$packageName")
						}
						safeStart(intent)
					}
					result.success(true)
				}

				"isNotificationListenerEnabled" -> {
					val enabled = PlaybackNotificationListenerService.isEnabled(this)
					// The app asks on startup and every time the user rechecks —
					// the cheapest moment to catch a grant that changed while the
					// service was running and re-word its notification. Revocation
					// does not always reach onListenerDisconnected.
					MediaButtonForegroundService.notifyListenerStateChanged(this)
					result.success(enabled)
				}

				"openNotificationListenerSettings" -> {
					safeStart(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
					result.success(true)
				}

				"isMiuiDevice" -> {
					val manufacturer = Build.MANUFACTURER.lowercase()
					result.success(manufacturer.contains("xiaomi") || manufacturer.contains("redmi") || manufacturer.contains("poco"))
				}

				"openMiuiAutostartSettings" -> {
					val intent = Intent("miui.intent.action.OP_AUTO_START").apply {
						addCategory(Intent.CATEGORY_DEFAULT)
					}
					safeStart(intent)
					result.success(true)
				}

				"setMusicProvider" -> {
					val provider = MusicProvider.fromId(call.argument<String>("provider"))
					prefs().edit()
						.putString(AppConstants.KEY_MUSIC_PROVIDER, provider.id)
						.apply()
					result.success(true)
				}

				"setMusicRoutingMode" -> {
					// Stored separately from the picked provider: an install
					// upgraded from a build without this key stays on "picker".
					val mode = MusicRoutingMode.fromId(call.argument<String>("mode"))
					prefs().edit()
						.putString(AppConstants.KEY_MUSIC_ROUTING_MODE, mode.id)
						.apply()
					result.success(true)
				}

				"getMusicSessions" -> {
					// Both lists are empty without notification access, which
					// is the honest answer, not an error.
					result.success(
						mapOf(
							"playing" to MusicProvider.playing(this).map { it.id },
							"lastPlaying" to MusicProvider.lastPlaying(this)?.id
						)
					)
				}

				"isMusicAppInstalled" -> {
					val provider = MusicProvider.fromId(call.argument<String>("provider"))
					val installed = try {
						packageManager.getPackageInfo(provider.packageName, 0)
						true
					} catch (_: Exception) {
						false
					}
					result.success(installed)
				}

				"openMusicApp" -> {
					val provider = MusicProvider.fromId(call.argument<String>("provider"))
					val launchIntent = packageManager.getLaunchIntentForPackage(provider.packageName)
					if (launchIntent != null) {
						safeStart(launchIntent)
						result.success(true)
					} else {
						result.success(false)
					}
				}

				"setRuleConfig" -> {
					val archiveRemoveEnabled = call.argument<Boolean>("archiveRemoveEnabled") ?: false
					val archiveName = call.argument<String>("archivePlaylistName")?.trim().orEmpty()
					val bestEnabled = call.argument<Boolean>("bestEnabled") ?: false
					val bestName = call.argument<String>("bestPlaylistName")?.trim().orEmpty()
					val bestThreshold = call.argument<Int>("bestThreshold")
						?.takeIf { it >= 1 }
						?: AppConstants.DEFAULT_BEST_THRESHOLD
					val followArtistEnabled = call.argument<Boolean>("followArtistEnabled") ?: false
					val followArtistThreshold = call.argument<Int>("followArtistThreshold")
						?.takeIf { it >= 1 }
						?: AppConstants.DEFAULT_FOLLOW_ARTIST_THRESHOLD
					val likeCooldownEnabled = call.argument<Boolean>("likeCooldownEnabled") ?: true
					val likeCooldownMinutes = call.argument<Int>("likeCooldownMinutes")
						?.takeIf { it >= 0 }
						?: AppConstants.DEFAULT_LIKE_COOLDOWN_MINUTES

					prefs().edit()
						.putBoolean(AppConstants.KEY_RULE_ARCHIVE_REMOVE_ENABLED, archiveRemoveEnabled)
						.putString(AppConstants.KEY_RULE_ARCHIVE_PLAYLIST_NAME, archiveName)
						.putBoolean(AppConstants.KEY_RULE_BEST_ENABLED, bestEnabled)
						.putString(AppConstants.KEY_RULE_BEST_PLAYLIST_NAME, bestName)
						.putInt(AppConstants.KEY_RULE_BEST_THRESHOLD, bestThreshold)
						.putBoolean(AppConstants.KEY_RULE_FOLLOW_ARTIST_ENABLED, followArtistEnabled)
						.putInt(AppConstants.KEY_RULE_FOLLOW_ARTIST_THRESHOLD, followArtistThreshold)
						.putBoolean(AppConstants.KEY_RULE_LIKE_COOLDOWN_ENABLED, likeCooldownEnabled)
						.putInt(AppConstants.KEY_RULE_LIKE_COOLDOWN_MINUTES, likeCooldownMinutes)
						.apply()
					result.success(true)
				}

				"setLikeCounterConfig" -> {
					val expiresAt = call.argument<Number>("expiresAtEpochMs")?.toLong() ?: 0L
					prefs().edit()
						.putString(
							AppConstants.KEY_COUNTER_SPREADSHEET_ID,
							call.argument<String>("spreadsheetId") ?: "",
						)
						.putString(
							AppConstants.KEY_COUNTER_CLIENT_ID,
							call.argument<String>("clientId") ?: "",
						)
						.putString(
							AppConstants.KEY_COUNTER_CLIENT_SECRET,
							call.argument<String>("clientSecret") ?: "",
						)
						.putString(
							AppConstants.KEY_COUNTER_ACCESS_TOKEN,
							call.argument<String>("accessToken") ?: "",
						)
						.putString(
							AppConstants.KEY_COUNTER_REFRESH_TOKEN,
							call.argument<String>("refreshToken") ?: "",
						)
						.putLong(AppConstants.KEY_COUNTER_TOKEN_EXPIRES_AT, expiresAt)
						.apply()
					result.success(true)
				}

				"playFeedbackTone" -> {
					val success = call.argument<Boolean>("success") ?: true
					FeedbackPlayer.play(this, success)
					result.success(true)
				}

				// Session-first YouTube Music like; Dart owns the tone and log line.
				"likeYouTubeMusic" -> {
					val appContext = applicationContext
					val power = getSystemService(Context.POWER_SERVICE) as PowerManager
					val wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "LikeSpotify:ytmusic-like-ui")
					wakeLock.setReferenceCounted(false)
					wakeLock.acquire(YTM_LIKE_WAKE_LOCK_MS)
					ytmLikeExecutor.execute {
						var extras: (() -> Unit)? = null
						try {
							val reply = try {
								val liker = YouTubeMusicLiker(appContext)
								val liked = liker.like()
								// A counter failure never turns the like into a failure.
								val outcome = runCatching { liker.count(liked) }.getOrDefault(liked)
								extras = { liker.extraActions(outcome) }
								outcome.toChannelMap()
							} catch (e: Exception) {
								mapOf("outcome" to "failed", "message" to (e.message ?: "unexpected error"))
							}
							runOnUiThread { result.success(reply) }
							// Dart has its answer; the opt-in extras are slower still and
							// only ever log, so they run after the reply.
							runCatching { extras?.invoke() }
						} finally {
							if (wakeLock.isHeld) wakeLock.release()
						}
					}
				}

				else -> result.notImplemented()
			}
		}

		EventChannel(flutterEngine.dartExecutor.binaryMessenger, AppConstants.CHANNEL_EVENTS)
			.setStreamHandler(this)
	}

	override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
		eventSink = events
		isFlutterAttached = true
		localReceiver = object : BroadcastReceiver() {
			override fun onReceive(context: Context, intent: Intent) {
				when (intent.action) {
					AppConstants.ACTION_MEDIA_EVENT -> {
						val value = intent.getStringExtra(AppConstants.EXTRA_EVENT) ?: return
						eventSink?.success(mapOf("type" to "media", "value" to value))
					}

					AppConstants.ACTION_LOG_EVENT -> {
						val value = intent.getStringExtra(AppConstants.EXTRA_LOG) ?: return
						val payload = mutableMapOf<String, Any?>("type" to "log", "value" to value)
						intent.getStringExtra(AppConstants.EXTRA_LOG_ACTION_TYPE)?.let { payload["actionType"] = it }
						intent.getStringExtra(AppConstants.EXTRA_LOG_TARGET_ID)?.let { payload["targetId"] = it }
						intent.getStringExtra(AppConstants.EXTRA_LOG_RESULT)?.let { payload["result"] = it }
						if (intent.hasExtra(AppConstants.EXTRA_LOG_HTTP_CODE)) {
							payload["httpCode"] = intent.getIntExtra(AppConstants.EXTRA_LOG_HTTP_CODE, 0)
						}
						eventSink?.success(payload)
					}

					AppConstants.ACTION_SERVICE_STATE -> {
						val value = intent.getBooleanExtra(AppConstants.EXTRA_ACTIVE, false)
						eventSink?.success(mapOf("type" to "state", "value" to value))
					}

					AppConstants.ACTION_TRIGGER_LIKE -> {
						eventSink?.success(mapOf("type" to "trigger_like"))
					}
				}
			}
		}

		val filter = IntentFilter().apply {
			addAction(AppConstants.ACTION_MEDIA_EVENT)
			addAction(AppConstants.ACTION_LOG_EVENT)
			addAction(AppConstants.ACTION_SERVICE_STATE)
			addAction(AppConstants.ACTION_TRIGGER_LIKE)
		}
		LocalBroadcastManager.getInstance(this).registerReceiver(localReceiver!!, filter)
	}

	override fun onCancel(arguments: Any?) {
		detachFromFlutter()
	}

	/**
	 * Also clears the attachment, because [onCancel] alone does not.
	 *
	 * [onCancel] fires when *Dart* cancels the subscription. Swiping the task
	 * out of recents tears the engine down without Dart ever getting there, so
	 * `onCancel` never runs and [isFlutterAttached] — a process-wide flag —
	 * stays true for the life of the process. [MediaButtonForegroundService]
	 * then keeps delegating every matched trigger to an engine that is gone
	 * instead of falling back to [SpotifyLikeWorker], and the like is silently
	 * lost. That is the one case the fallback exists for, so the flag has to
	 * be cleared from the activity lifecycle as well.
	 *
	 * Clearing it on a destroy that is only an activity recreate is harmless:
	 * the engine goes with the activity either way, and the next [onListen]
	 * sets it back.
	 */
	override fun onDestroy() {
		detachFromFlutter()
		super.onDestroy()
	}

	private fun detachFromFlutter() {
		isFlutterAttached = false
		localReceiver?.let {
			LocalBroadcastManager.getInstance(this).unregisterReceiver(it)
		}
		localReceiver = null
		eventSink = null
	}

	/**
	 * Switches the listener on.
	 *
	 * `service_enabled` is not a record of what the user asked for, it is this
	 * app's answer to "is the listener running": `isServiceEnabled` reports the
	 * UI from it and [BootCompletedReceiver] restarts from it. So it is written
	 * only once the system has accepted the start. Writing it unconditionally
	 * would let a refused start leave the app claiming to listen while nothing
	 * is running — exactly the state #162 went to some trouble to rule out.
	 *
	 * @return true if the listener is now on.
	 */
	private fun startListenerService(): Boolean {
		val intent = Intent(this, MediaButtonForegroundService::class.java).apply {
			action = MediaButtonForegroundService.ACTION_START
		}
		if (!MediaButtonForegroundService.start(this, intent)) {
			return false
		}
		prefs().edit().putBoolean(AppConstants.KEY_SERVICE_ENABLED, true).apply()
		return true
	}

	private fun stopListenerService() {
		val intent = Intent(this, MediaButtonForegroundService::class.java).apply {
			action = MediaButtonForegroundService.ACTION_STOP
		}
		startService(intent)
		prefs().edit().putBoolean(AppConstants.KEY_SERVICE_ENABLED, false).apply()
	}

	private fun safeStart(intent: Intent) {
		intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
		runCatching { startActivity(intent) }
	}

	private fun prefs() = getSharedPreferences(AppConstants.PREFS, Context.MODE_PRIVATE)
}
