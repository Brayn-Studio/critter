package local.critter.phone.ui.pairing

import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import java.util.concurrent.Executors

/** A camera preview that reports the text of the first QR code it reads (ZXing, no Play services). */
@Composable
fun QrScanner(onResult: (String) -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val latest by rememberUpdatedState(onResult)
    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }
    val provider = remember { arrayOfNulls<ProcessCameraProvider>(1) }

    DisposableEffect(Unit) {
        onDispose {
            // Leaving the screen must release the camera even though the activity lives on.
            provider[0]?.unbindAll()
            analysisExecutor.shutdown()
        }
    }

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            val view = PreviewView(ctx).apply { scaleType = PreviewView.ScaleType.FILL_CENTER }
            val providerFuture = ProcessCameraProvider.getInstance(ctx)
            providerFuture.addListener({
                val cameraProvider = providerFuture.get().also { provider[0] = it }
                val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                val reader = QRCodeReader()
                val hints = mapOf(
                    DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                    DecodeHintType.TRY_HARDER to true,
                )
                analysis.setAnalyzer(analysisExecutor) { image ->
                    val text = decode(reader, image, hints)
                    image.close()
                    if (text != null) ContextCompat.getMainExecutor(ctx).execute { latest(text) }
                }
                try {
                    cameraProvider.unbindAll()
                    cameraProvider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                } catch (_: Exception) {
                    // No back camera, or it is in use: the manual path is still there.
                }
            }, ContextCompat.getMainExecutor(context))
            view
        },
    )
}

/** Decodes a QR code from the luminance (Y) plane of [image]; null if there is none in this frame. */
private fun decode(reader: QRCodeReader, image: ImageProxy, hints: Map<DecodeHintType, Any>): String? {
    val plane = image.planes[0]
    val width = image.width
    val height = image.height
    val rowStride = plane.rowStride
    val buffer = plane.buffer
    // Rows can be padded: copy them out tightly packed.
    val data = ByteArray(width * height)
    for (row in 0 until height) {
        buffer.position(row * rowStride)
        buffer.get(data, row * width, width)
    }
    val source = PlanarYUVLuminanceSource(data, width, height, 0, 0, width, height, false)
    return try {
        reader.decode(BinaryBitmap(HybridBinarizer(source)), hints).text
    } catch (_: Exception) {
        null
    } finally {
        reader.reset()
    }
}
