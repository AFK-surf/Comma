package codec

// Resampler converts a mono PCM16 stream between sample rates with linear
// interpolation. Downsampling first applies a moving-average low-pass filter
// whose width is the rate ratio, which is enough to keep voice intelligible
// between 8 kHz and 24 kHz. Positions use exact integer arithmetic, so a long
// stream does not drift.
type Resampler struct {
	inRate, outRate int
	// pos is the next output position in units of 1/outRate input samples,
	// relative to buf[0].
	pos int64
	buf []int16
	// Low-pass state for downsampling.
	window  int
	history []int32
	next    int
	filled  int
	sum     int32
}

// NewResampler returns a resampler from inRate to outRate.
func NewResampler(inRate, outRate int) *Resampler {
	r := &Resampler{inRate: inRate, outRate: outRate}
	if inRate > outRate {
		r.window = (inRate + outRate - 1) / outRate
		r.history = make([]int32, r.window)
	}
	return r
}

// Process converts the next chunk of input. Output for the last input
// samples may be held back until more input or Flush arrives.
func (r *Resampler) Process(in []int16) []int16 {
	if r.inRate == r.outRate {
		out := make([]int16, len(in))
		copy(out, in)
		return out
	}
	r.buf = append(r.buf, r.lowPass(in)...)
	out := make([]int16, 0, len(in)*r.outRate/r.inRate+2)
	step := int64(r.inRate)
	unit := int64(r.outRate)
	for {
		i := r.pos / unit
		if i+1 >= int64(len(r.buf)) {
			break
		}
		frac := r.pos % unit
		a, b := int64(r.buf[i]), int64(r.buf[i+1])
		out = append(out, int16(a+(b-a)*frac/unit))
		r.pos += step
	}
	r.drop()
	return out
}

// Flush emits output for the held-back tail of the input.
func (r *Resampler) Flush() []int16 {
	if r.inRate == r.outRate {
		return nil
	}
	var out []int16
	unit := int64(r.outRate)
	for {
		i := r.pos / unit
		if i >= int64(len(r.buf)) {
			break
		}
		out = append(out, r.buf[i])
		r.pos += int64(r.inRate)
	}
	r.drop()
	return out
}

func (r *Resampler) drop() {
	unit := int64(r.outRate)
	n := r.pos / unit
	if n > int64(len(r.buf)) {
		n = int64(len(r.buf))
	}
	r.buf = append(r.buf[:0], r.buf[n:]...)
	r.pos -= n * unit
}

func (r *Resampler) lowPass(in []int16) []int16 {
	if r.window <= 1 {
		return in
	}
	out := make([]int16, len(in))
	for i, s := range in {
		v := int32(s)
		r.sum += v - r.history[r.next]
		r.history[r.next] = v
		r.next = (r.next + 1) % r.window
		if r.filled < r.window {
			r.filled++
		}
		out[i] = int16(r.sum / int32(r.filled))
	}
	return out
}
