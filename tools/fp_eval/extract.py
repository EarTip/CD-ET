"""ESC-50 각 클립을 앱과 같은 방식(16kHz, 15600 창, 0.25초 hop)으로 잘라
창마다 RMS와 model.tflite 확률을 저장한다. 판정 로직은 simulate.py에서 처리."""
import sys, csv, numpy as np, soundfile as sf, librosa
from multiprocessing import Pool
from ai_edge_litert.interpreter import Interpreter

ESC = sys.argv[1]
MODELS = sys.argv[2]
OUT = sys.argv[3]
SR, WIN, HOP = 16000, 15600, 4000

_y = _h = _hm = None

def init():
    global _y, _h, _hm
    _y = Interpreter(f'{MODELS}/yamnet_embedding.tflite'); _y.allocate_tensors()
    _h = Interpreter(f'{MODELS}/model.tflite'); _h.allocate_tensors()
    _hm = Interpreter(f'{MODELS}/model_multilabel.tflite'); _hm.allocate_tensors()

def run(it, x):
    it.set_tensor(it.get_input_details()[0]['index'], x)
    it.invoke()
    return it.get_tensor(it.get_output_details()[0]['index']).copy()

def proc(fn):
    wav, sr = sf.read(f'{ESC}/audio/{fn}', dtype='float32')
    if wav.ndim > 1: wav = wav.mean(1)
    wav = librosa.resample(wav, orig_sr=sr, target_sr=SR)
    # 앱처럼 16bit PCM 양자화
    wav = np.clip(np.round(wav * 32768), -32768, 32767) / 32768.0
    rows = []
    for s in range(0, len(wav) - WIN + 1, HOP):
        w = wav[s:s + WIN].astype(np.float32)
        rms = float(np.sqrt(np.mean(w * w)))
        emb = run(_y, w)
        p = run(_h, emb[None, :])[0]
        pm = run(_hm, emb[None, :])[0]
        rows.append((rms, *p, *pm))
    return fn, np.array(rows, dtype=np.float32)

if __name__ == '__main__':
    meta = list(csv.DictReader(open(f'{ESC}/meta/esc50.csv')))
    fns = [m['filename'] for m in meta]
    with Pool(initializer=init) as pool:
        res = dict(pool.imap_unordered(proc, fns, chunksize=8))
    np.savez_compressed(OUT, **res)
    print('done', len(res))
