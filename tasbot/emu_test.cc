/* This tests the interface to the emulator library
   for correctness, by playing back the movie karate.fm2
   against the rom karate.nes, and checking that
   the game is won and that the RAM has the right
   contents. It also does some simple timing. */

#include <unistd.h>
#include <sys/types.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

#include "fceu/utils/md5.h"

#include "config.h"

#include "fceu/driver.h"
#include "fceu/drivers/common/args.h"

#include "fceu/state.h"

#include "fceu/fceu.h"
#include "fceu/types.h"

#include "../cc-lib/util.h"

#include "simplefm2.h"
#include "emulator.h"
#include "basis-util.h"

static int64 DumpMem() {
  for (int i = 0; i < 0x800; i++) {
    fprintf(stderr, "%02x", (uint8)RAM[i]);
    // if (i % 40 == 0) fprintf(stderr, "\n");
  }
  md5_context ctx;
  md5_starts(&ctx);
  md5_update(&ctx, RAM, 0x800);
  uint8 digest[16];
  md5_finish(&ctx, digest);
  fprintf(stderr, "  MD5: ");
  for (int i = 0; i < 16; i++)
    fprintf(stderr, "%02x", digest[i]);
  fprintf(stderr, "\n");
  uint64 res = 0;
  for (int i = 0; i < 8; i++) {
    res <<= 8;
    res |= 255 & digest[i];
  }
  return res;
}

static void PrintSavestate(const vector<uint8> &ss) {
  printf("Savestate:\n");
  for (int i = 0; i < ss.size(); i++) {
    printf("%02x", ss[i]);
  }
  printf("\n");
}

static void CheckLoc(int frame, uint32 expected) {
  fprintf(stderr, "Frame %d expect %u\n", frame, expected);
  uint32 loc = (RAM[0x0080] << 24) |
    (RAM[0x0081] << 16) |
    (RAM[0x0082] << 8) |
    (RAM[0x0083]);
  if (loc != expected) {
    fprintf(stderr, "At frame %d, expected %u, got %u\n",
	    frame, expected, loc);
    abort();
  }
}

// Note that fceu_frame is 1 plus the index in the input loop,
// because the UI displays the first frame as #1.
static void CheckCheckpoints(int fceu_frame) {
  // XXX read from golden file.
  switch (fceu_frame) {
  case 20: CheckLoc(fceu_frame, 0); break;
  case 21: CheckLoc(fceu_frame, 65536); break;
  case 4935: CheckLoc(fceu_frame, 196948); break;
  case 7674: CheckLoc(fceu_frame, 200273); break;
  case 7675: CheckLoc(fceu_frame, 200274); break;
  case 8123: CheckLoc(fceu_frame, 262144); break;
  case 11213: CheckLoc(fceu_frame, 265916); break;
  default:;
  }
}

static uint64 CrapHash(int a) {
  uint64 ret = ~a;
  ret *= 31337;
  ret ^= 0xDEADBEEF;
  ret = (ret >> 17) | (ret << (64 - 17));
  ret -= 911911911911;
  ret *= 65537;
  ret ^= 0xCAFEBABE;
  return ret;
}

static bool CompareByHash(int a, int b) {
  return CrapHash(a) < CrapHash(b);
}

int main(int argc, char *argv[]) {
  Emulator::Initialize("karate.nes");
  // loop playing the game
  vector<uint8> inputs = SimpleFM2::ReadInputs("karate.fm2");

  vector<uint8> basis = BasisUtil::LoadOrComputeBasis(inputs, 4935, "karate.basis");

  // The nth savestate is from before issuing the nth input.
  vector< vector<uint8> > savestates;

  int64 ss_total = 0;

  // XXXXXX
  // inputs.resize(10);

  fprintf(stderr, "Running %d steps...\n", inputs.size());
  for (int i = 0; i < inputs.size(); i++) {
    // XXX don't think this should ever happen.
    if (!GameInfo) {
      fprintf(stderr, "Gameinfo became null?\n");
      return -1;
    }

    vector<uint8> v;
    Emulator::SaveEx(&v, &basis);
    ss_total += v.size();
    savestates.push_back(v);

    Emulator::Step(inputs[i]);

    // The FCEUX UI indexes frames starting at 1.
    CheckCheckpoints(i + 1);
  }

#if 0
  /*
  PrintSavestate(savestates[0]);
  PrintSavestate(savestates[4935]);
  PrintSavestate(savestates[8123]);
  */

  if (savestates.size() > 9000) {
    vector<uint8> diff;
    for (int i = 0; i < savestates[4935].size(); i++) {
      diff.push_back(savestates[8123][i] - savestates[4935][i]);
    }

    PrintSavestate(diff);
  }
#endif

  if (0x46e75713b56aea30 == Emulator::RamChecksum()) {
    fprintf(stderr, "Memory OK.\n");
  } else {
    fprintf(stderr, "WRONG CHECKSUM\n");
    return -1;
  }

  fprintf(stderr, "\nTest random replay of savestates:\n");
  // Now run through each state in random order. Load it, then execute a step,
  // then check that we get to the same state as before.
  vector<int> order;
  for (int i = 0; i < inputs.size(); i++) {
    order.push_back(i);
  }
  std::sort(order.begin(), order.end(), CompareByHash);
  for (int i = 0; i < order.size(); i++) {
    int frame = order[i];
    Emulator::LoadEx(&savestates[frame], &basis);
    Emulator::Step(inputs[frame]);
    vector<uint8> res;
    Emulator::SaveEx(&res, &basis);
    CheckCheckpoints(frame + 1);
    if (frame + 1 < savestates.size()) {
      const vector<uint8> &expected = savestates[frame + 1];
      if (res != expected) {
	fprintf(stderr, "Got a different savestate from frame %d to %d.\n",
		frame, frame + 1);
	abort();
      }
    }
  }
  fprintf(stderr, "Savestates are ok.\n");

  fprintf(stderr, "Total for %d savestates: %.2fmb (avg %.2f bytes)\n",
          savestates.size(), ss_total / (1024.0 * 1024.0),
	  ss_total / (double)savestates.size());

  Emulator::Shutdown();

  // exit the infrastructure
  FCEUI_Kill();
  return 0;
}