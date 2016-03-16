library(GenomicRanges,quietly = !interactive())
library(utils,quietly = !interactive())
library(matrixStats,quietly = !interactive())

calc.zscore <- function(v) (v-mean(v))/sd(v)

estimate.global.bayesian.mixture <- function(ints,depth,inttable,N=1100,burnin=100,pruning=NULL,
                                                        with.distance.weight=F,multiply=T,show.progress=F,
                                                        lambda0.init=1,lambda1.init=5,suppress.counts.higher.than=30,
                                                        mini.model=T) {
  S <- nrow(ints)
  
  d <- GRanges(seqnames=as.character(depth$V1),ranges=IRanges(depth$V2,depth$V3),strand='*')
  g1 <- GRanges(seqnames=as.character(ints$V1),ranges=IRanges(ints$V2,ints$V3),strand='*')
  g2 <- GRanges(seqnames=as.character(ints$V4),ranges=IRanges(ints$V5,ints$V6),strand='*')
  
  m1 <- match(g1,d)
  m2 <- match(g2,d)
  counts <- ints[,7]
  d <- depth[,4]
  intdist <- distance(g1,g2)
  interchromsomal <- is.na(intdist)
  #if(any(is.na(intdist))) {
  #  intdist[is.na(intdist)] <- max(intdist,na.rm=T)
  #}
  
  if(is.null(pruning) || pruning < 1) {
    pruning <- N+1 # will never prune
  } 
  
  if(!multiply) {
    sdepth <- rowSums(cbind(d[m1],d[m2]))
    msdepth <- median(sdepth)
  } else {
    sdepth <- rowProds(cbind(d[m1],d[m2]))
    msdepth <- median(sdepth)
  }
  
  f1 <- paste(ints$V1,ints$V2,ints$V3,sep='_')
  f2 <- paste(ints$V4,ints$V5,ints$V6,sep='_')
  
  m1 <- match(f1,rownames(inttable))
  m2 <- match(f2,rownames(inttable))
  
  # frequency of interactions not including the present one
  #nint <- rowMeans(cbind(totint[m1]-1,totint[m2]-1)) # since each interaction counts itself in the table in the parent script
  
  #pint <- apply(cbind(inttable[m1],inttable[m2],counts),1,function(r) { idx <- as.integer(colnames(inttable))<r[3]; sum(r[1:2])}
  countm <- t(mapply(function(x1,x2,n) {
    idx <- as.integer(colnames(inttable))<n
    
    z <- inttable[c(x1,x2),]

    a <- if(!any(idx)) 0 else sum(z[,idx])
    b <- sum(z)-a
    c(a,b)
  },as.list(m1),as.list(m2),as.list(counts),SIMPLIFY=T))
  
  
  depthscore <- floor(sdepth/msdepth)
  alphaparam <- 1+countm[,1]
  betaparam <- 1+depthscore+countm[,2]
  

  
  pp <- rep(.5,S)
  
  if (!mini.model) {
    ret <- list(
      z = vector("list",N),
      p1 = c(list(pp),vector("list",N)),
      mp = vector("list",N),
      lambda0 = c(lambda0.init,rep(NA_real_,N)),
      lambda1 = c(lambda1.init,rep(NA_real_,N)),
      lambdad1 = vector("list",N),
      lambdad0 = vector("list",N)
    )
  } else {
    ret <- list(
      lambda0 = c(lambda0.init,rep(NA_real_,N)),
      lambda1 = c(lambda1.init,rep(NA_real_,N))
    )
    zm = rep(0,length(N))
  }
  
  totcounts <- sum(counts)
  
  lambdad1 <- lamdbad0 <- rep(0,length(counts))
  
  
  if(show.progress) pb <- txtProgressBar()
  
  suppress <- counts > suppress.counts.higher.than
  
  
  for( i in 1:N ) {
    lambda0 <- ret$lambda0[i]
    lambda1 <- ret$lambda1[i]
    g1 <- pp*dpois(counts,lambda1 + lambdad1)
    g2 <- (1-pp) * dpois(counts,lambda0 + lamdbad0)
    
    vp <- g1/rowSums(cbind(g1,g2)) 
    
    # Sometimes the counts value in dpois is so extreme the loss of precision causes the value to be 0, need to correct for this
    # if in this case the counts value is closer to lambda1 than lambda0, give it a probability of .999, otherwise .001
    if(any(is.na(vp))) {
      b<- is.na(vp)
      vp[b] <- ifelse(counts[b]>=lambda1,.999,.001)
    }
    
    vz <- rbinom(S,1,vp)
    
    pp <- rbeta(S,alphaparam+vz,betaparam+(1-vz)) 
    
    
    if(!mini.model) {
      ret$z[[i]] <- vz
      ret$mp[[i]] <- vp
      ret$p1[[i+1]] <- pp
    } else if(mini.model && i > burnin && ((i-burnin) %% pruning) != 0 ) {
      ret$zm <- ret$zm + vz
    }
    
    b <- vz == 0 & !suppress
    r0 <- sum(counts[b])
    n <- sum(b)

    l0 <- rgamma(1,r0,n)
    
    l1 <- l0
    
    b <- vz == 1 & !suppress
    r1 <- sum(counts[b])
    n <- sum(b)
    
    
    
    l1x <- rgamma(1,r1,n)
    l1 <- max(l1,l1x)
    
    ret$lambda0[i+1] <- l0
    ret$lambda1[i+1] <- l1
    
    
    x <- log10(intdist[vz==1 & !interchromsomal]+1)

    s1 <- smooth.spline(x,pmax(counts[vz==1& !is.na(intdist)]-l1,0))
    x <- log10(intdist[vz==0 & !interchromsomal]+1)
    
    s0 <- smooth.spline(x,pmax(counts[vz==0& !is.na(intdist)]-l0,0))
    
    x <- log10(intdist)
    if(any(interchromsomal)) x[interchromsomal] <- 0
    
    lambdad1 <- predict(s1,x)$y
    if(any(interchromsomal)) lambdad1[is.na(x)] <- 0 ## is there better way to handle this?
    

    lambdad0 <- predict(s0,x)$y
    if(any(interchromsomal)) lambdad0[is.na(x)] <- 0
    
    if( !mini.model) {
      ret$lambdad1[[i]] <- lambdad1
      ret$lambdad0[[i]] <- lambdad0
    }
    if(show.progress) setTxtProgressBar(pb,i/N)
  }
  
  if(show.progress) close(pb)
  #ret <- list(s=l,l0=lambda0,l1=lambda1)
  if(!is.null(burnin) && is.numeric(burnin) && burnin > 0 && burnin < N) {
      bn <- lapply(ret,function(l) l[1:burnin])
      idx <- -(1:burnin)
      ret <- lapply(ret,function(v) v[idx])
      ret$burnin <- bn
  }
  if(!is.null(pruning) && pruning > 1) {
    l <- length(ret$lambda0)
    
    idx <- seq(1,l,by=pruning)
    w <- which(names(ret)=="burnin")
    if(length(w)>0) {
      bn <- ret$burnin
      ret <- lapply(ret[-w],function(l) l[-idx])
      ret$burnin <- bn
    } else {
      ret <- lapply(ret[-w],function(l) l[-idx])
    }
  } 
  ret <- c(ret,list(sdepth=sdepth,msdepth=msdepth,intdist=intdist))
  if(mini.model) ret <- c(ret,list(zm=zm))
  
  ret
}


estimate.global.bayesian.weighed.depth.mixture <- function(ints,depth,N=1100,burnin=100,pruning=NULL,with.distance.weight=F,multiply=T,show.progress=F,
                                             lambda0.init=1,lambda1.init=5) {
  S <- nrow(ints)
  
  d <- GRanges(seqnames=as.character(depth$V1),ranges=IRanges(depth$V2,depth$V3),strand='*')
  g1 <- GRanges(seqnames=as.character(ints$V1),ranges=IRanges(ints$V2,ints$V3),strand='*')
  g2 <- GRanges(seqnames=as.character(ints$V4),ranges=IRanges(ints$V5,ints$V6),strand='*')
  
  m1 <- match(g1,d)
  m2 <- match(g2,d)
  counts <- ints[,7]
  d <- depth[,4]
  
  if(!multiply) {
    sdepth <- rowSums(cbind(d[m1],d[m2]))
    msdepth <- median(sdepth)
  } else {
    sdepth <- rowProds(cbind(d[m1],d[m2]))
    msdepth <- median(sdepth)
  }
  
  #print(c(msdepth,range(sdepth)))
  
  pp <- rep(.5,S)
  
  ret <- list(z=vector("list",N),
              p1=c(list(pp),vector("list",N)),
              mp=vector("list",N),
              lambda0=c(lambda0.init,rep(NA_real_,N)),
              lambda1=c(lambda1.init,rep(NA_real_,N)))

  
  totcounts <- sum(counts)

  
  if(show.progress) pb <- txtProgressBar()
  
  for( i in 1:N ) {
    lambda0 <- ret$lambda0[i]
    lambda1 <- ret$lambda1[i]
    g1 <- pp*dpois(counts,lambda1)
    g2 <- (1-pp) * dpois(counts,lambda0)
    
    vp <- g1/rowSums(cbind(g1,g2)) 

    if(any(is.na(vp))) {
      b<- is.na(vp)
      vp[b] <- ifelse(counts[b]>=lambda1,.999,.001)
    }
    
    vz <- rbinom(S,1,vp)

    pp <- rbeta(S,sdepth/msdepth+vz,1+(1-vz)) #msdepth/msdepth=1
    
    
    ret$z[[i]] <- vz
    ret$mp[[i]] <- vp
    ret$p1[[i+1]] <- pp
    
    r <- sum(counts[vz==0])
    n <- sum(vz==0)
    
    l0 <- rgamma(1,r,n)


    l1 <- rgamma(1,totcounts-r,S-n)#sum(vz==1))
    l1 <- max(l0,l1) # cap the lower bound of l1 so we don't have to reshuffle group IDs
    
    ret$lambda0[i+1] <- l0
    ret$lambda1[i+1] <- l1

    #print(c(l0,l1))
    if(show.progress) setTxtProgressBar(pb,i/N)
  }
  
  if(show.progress) close(pb)
  if(!is.null(burnin) && is.numeric(burnin) && burnin > 0 && burnin < N) {
    bn <- lapply(ret,function(l) l[1:burnin])
    idx <- -(1:burnin)
    ret <- lapply(ret,function(v) v[idx])
    ret$burnin <- bn
  }
  ret <- c(ret,list(sdepth=sdepth,msdepth=msdepth,intdist=intdist))
  ret
}


estimate.global.bayesian.no.depth.mixture <- function(ints,depth,N=1100,burnin=100,pruning=NULL,with.distance.weight=F,multiply=T,show.progress=F) {
  S <- nrow(ints)
  
  d <- GRanges(seqnames=as.character(depth$V1),ranges=IRanges(depth$V2,depth$V3),strand='*')
  g1 <- GRanges(seqnames=as.character(ints$V1),ranges=IRanges(ints$V2,ints$V3),strand='*')
  g2 <- GRanges(seqnames=as.character(ints$V4),ranges=IRanges(ints$V5,ints$V6),strand='*')
  
  m1 <- match(g1,d)
  m2 <- match(g2,d)
  counts <- ints[,7]
  d <- depth[,4]
  
  
  if(!multiply) {
    sdepth <- rowSums(cbind(d[m1],d[m2]))
    msdepth <- median(sdepth)
  } else {
    sdepth <- rowProds(cbind(d[m1],d[m2]))
    msdepth <- median(sdepth)
  }
  
  
  print(c(msdepth,range(sdepth)))
  
  l <- lapply(1:S,function(i) list(z=rep(NA_integer_,N),p1=c(.5,rep(NA_real_,N)),mp=rep(NA_real_,N)))
  pp <- rep(.5,S)
  
  lambda0 <- c(1,rep(NA_real_,N))
  lambda1 <- c(5,rep(NA_real_,N))
  
  
  totcounts <- sum(counts)
  
  
  if(show.progress) pb <- txtProgressBar()
  
  
  for( i in 1:N ) {
    #vp <- f(pp,lambda1[i],lambda0[i])
    g1 <- pp*dpois(counts,lambda1[i])
    g2 <- (1-pp) * dpois(counts,lambda0[i])
    
    vp <- g1/rowSums(cbind(g1,g2)) 
    if(any(is.na(vp))) {
      b<- is.na(vp)
      vp[b] <- as.integer(counts[b]>=lambda1[i])
    }    
    vz <- rbinom(S,1,vp)
    
    pp <- rbeta(S,1+vz,1+(1-vz)) 
    
    l <- mapply(function(lx,z,mp,p){
      lx$z[i] <- z
      lx$mp[i] <- mp
      lx$p1[i+1] <- p
      lx
    },l,as.list(vz),as.list(vp),as.list(pp),SIMPLIFY=F)
    
    l0 <- 0
    r <- sum(counts[vz==0])
    n <- sum(vz==0)
    
    l0 <- rgamma(1,r,n)
    
    l1 <- l0
    #r <- totcounts - r #sum(counts[vz==1])
    
    l1x <- rgamma(1,totcounts-r,S-n)#sum(vz==1))
    l1 <- max(l1,l1x)
    
    lambda0[i+1] <- l0
    lambda1[i+1] <- l1
    
    print(c(l0,l1))
    if(show.progress) setTxtProgressBar(pb,i/N)
  }
  
  if(show.progress) close(pb)
  ret <- list(s=l,l0=lambda0,l1=lambda1)
  if(!is.null(burnin) && is.numeric(burnin) && burnin > 0) {
    orig <- ret
    idx <- -(1:burnin)
    ret <- lapply(ret,function(v) v[idx])
    ret$orig <- orig
  }
  ret <- c(ret,list(sdepth=sdepth,msdepth=msdepth))
  ret
}


extract.no.depth.bayesian.prob <- function(model) {
    sapply(model$s,function(v) sum(v$z)/length(v$z))
}

extract.global.bayesian.mixture.prob <- function(model) {
  if( "zm" %in% names(model)) {
    return(model$zm / length(model$lambda0))
  } else {
    m <- do.call(rbind,model$z)
    N <- nrow(m)
    return(colSums(m)/N)
  }
}
