(() => {
  const anchors = document.querySelectorAll('[data-test-id="VIBE_PLAYERBAR"], [data-test-id="PLAYERBAR_DESKTOP"], [data-test-id="PLAYERBAR"], [data-test-id="NEXT_TRACK_BUTTON"]');
  let state;
  for (const element of anchors) {
    let fiber = element[Object.keys(element).find(key => key.startsWith('__reactFiber'))];
    for (let depth = 0; fiber && depth < 180; depth++, fiber = fiber.return) {
      const value = fiber.memoizedProps?.value;
      if (value?.state?.queueState?.currentEntity && value.state.playerState) {state = value.state;break;}
    }
    if (state) break;
  }
  if (!state) return {available:false};
  const entity = state.queueState.currentEntity.value?.entity;
  const meta = entity?.data?.meta;
  const progress = state.playerState.progress.value;
  return {available:true,status:state.playerState.status.value,track:meta ? {
    id:String(meta.id),title:meta.title,version:meta.version,
    artists:(meta.artists || []).map(artist => artist.name),
    cover:meta.coverUri ? 'https://' + meta.coverUri.replace(/^https?:\/\//,'').replace('%%','400x400') : null,
    duration:meta.durationMs / 1000
  } : null,position:progress?.position || 0,duration:progress?.duration || meta?.durationMs / 1000 || 0};
})()
