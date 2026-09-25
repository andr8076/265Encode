#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any

from hevcplan_contract import PlanError, command_output, encoder_runtime
from hevcplan_quality import video_encode_args


def stream_counts(path: Path) -> dict[str, int]:
    data=json.loads(command_output(["ffprobe","-v","error","-show_entries","stream=codec_type","-of","json",str(path)]));result={k:0 for k in ("video","audio","subtitle","data","attachment")}
    for stream in data.get("streams",[]):
        kind=stream.get("codec_type")
        if kind in result:result[kind]+=1
    return result


def validate_output(source: Path, output: Path) -> None:
    if not output.is_file() or output.stat().st_size<=0:raise PlanError("HEVC execution produced no output file.")
    if output.stat().st_size >= source.stat().st_size:
        raise PlanError("HEVC execution rejected the result because it is not smaller than the source.")
    lines=command_output(["ffprobe","-v","error","-select_streams","V:0","-show_entries","stream=codec_name","-of","csv=p=0",str(output)]).splitlines();codec=lines[0].strip() if lines else ""
    if codec!="hevc":raise PlanError(f"Completed output codec was {codec or 'unreadable'}, not HEVC.")
    def duration(path:Path)->float:
        try:return float(command_output(["ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0",str(path)]).splitlines()[0])
        except (ValueError,IndexError):return 0.0
    a,b=duration(source),duration(output)
    if a>0 and b>0 and abs(a-b)>2:raise PlanError("Completed output duration differs from the input by more than two seconds.")
    decode=subprocess.run(["ffmpeg","-hide_banner","-loglevel","error","-xerror","-nostdin","-i",str(output),"-map","0:V:0","-map","0:a?","-f","null","-"],text=True,capture_output=True,check=False)
    if decode.returncode!=0:raise PlanError(decode.stderr.strip() or "Completed output failed full video/audio decode validation.")
    if stream_counts(source)!=stream_counts(output):raise PlanError("Completed output did not preserve every stream type.")


def _audio_args(recipe: dict[str,Any])->list[str]:
    result:list[str]=[]
    for track in recipe["audio"]["tracks"]:
        index=int(track["output_audio_index"])
        if track["mode"]=="opus":
            result += [f"-c:a:{index}","libopus",f"-b:a:{index}",str(track["bitrate"]),f"-vbr:a:{index}","on"]
        else:
            result += [f"-c:a:{index}","copy"]
    return result


def execute_direct(requirements: dict[str,Any], recipe: dict[str,Any], source: dict[str,Any])->dict[str,Any]:
    output=Path(requirements["output"])
    partial=output.with_name(f".{output.name}.encode265-partial-{os.getpid()}.mkv")
    video_partial=output.with_name(f".{output.name}.encode265-video-{os.getpid()}.mkv")
    primary=int(source["primary_stream_index"])
    others=[int(x.get("index") or 0) for x in source["streams"] if int(x.get("index") or 0)!=primary]
    try:
        partial.unlink(missing_ok=True);video_partial.unlink(missing_ok=True)
        global_args,video_args=video_encode_args(recipe["encoder"],recipe)
        ffmpeg,environment=encoder_runtime(recipe)
        if recipe["encoder"]=="hevc_qsv_legacy":
            video_command=[ffmpeg,"-hide_banner","-loglevel","error","-y",*global_args,"-i",requirements["input"],"-map",f"0:{primary}","-an","-sn","-dn",*video_args,"-f","matroska",str(video_partial)]
            process=subprocess.run(video_command,env=environment,text=True,capture_output=True,check=False)
            if process.returncode!=0:raise PlanError(process.stderr.strip() or "Legacy Intel HEVC video execution failed.")
            host_ffmpeg,host_environment=encoder_runtime({"encoder":"host_mux"})
            command=[host_ffmpeg,"-hide_banner","-loglevel","error","-y","-i",str(video_partial),"-i",requirements["input"],"-map","0:v:0"]
            for index in others:command += ["-map",f"1:{index}"]
            command += ["-map_metadata","1","-map_chapters","1","-copy_unknown","-c","copy",*_audio_args(recipe),"-max_muxing_queue_size","4096",str(partial)]
            environment=host_environment
        else:
            command=[ffmpeg,"-hide_banner","-loglevel","error","-y",*global_args,"-i",requirements["input"],"-map",f"0:{primary}"]
            for index in others:command += ["-map",f"0:{index}"]
            command += ["-map_metadata","0","-map_chapters","0","-copy_unknown","-c","copy",*video_args,*_audio_args(recipe),"-max_muxing_queue_size","4096",str(partial)]
        process=subprocess.run(command,env=environment,text=True,capture_output=True,check=False)
        if process.returncode!=0:raise PlanError(process.stderr.strip() or "HEVC mux/audio execution failed.")
        validate_output(Path(requirements["input"]),partial);os.replace(partial,output)
        return {"schema":"encode265.result","protocol_version":2,"status":"ok","exit_code":0,"input":requirements["input"],"output":str(output),"encoder":recipe["encoder"],"execution_owner":"265Encode"}
    finally:
        for path in (partial,video_partial):
            try:path.unlink()
            except OSError:pass
